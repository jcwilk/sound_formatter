#!/usr/bin/env ruby

require 'rubygems'
#require 'bundler/setup'
#Bundler.require(:default)
require 'open3'
require 'irb'

# start simple,
# each function expects the time index in seconds and returns the corresponding wave value

SAMPLE_RATE = 41_000 # samples per second
# Currently the sample calculation block and the sound functions all work based on samples
# so changing this value will pitch-shift any existing song scripts
# Still haven't decided if I want to make everything run on seconds or not...
# Seems like it's a missed opportunity to not calculate based on the exact sample integer,
# even if it's almost always converted to a float right away

BATCH_LENGTH = 0.1 # size of batch of samples to stream to sox, specified in seconds

NEXT_BATCH_HEAD_START = 0.4 # start processing this many seconds ahead of the next batch delivery time
# NB: setting this to lower than 0.2 causes ALSA underrun errors
# Basically I think some part of the pipeline is buffering too much and ALSA is running out of sound to play
# Using this to keep a buffer of 0.2s forward loaded in the pipeline keeps ALSA happy

FADE_FILTER_LENGTH = SAMPLE_RATE * 0.1 # samples (here in seconds) to fade in/out on every sound to avoid clicks
# NB: Not currently used, it's quite difficult to anticipate the end of a set of sounds efficiently

LINGER_TIMEOUT = 3.0 # seconds before the play thread self-immolates after the last sound it's played
# The first sound in a thread always has near zero latency, subsequent ones have latency based on NEXT_BATCH_HEAD_START and BATCH_LENGTH
# Set this lower for better average latency
# Set this higher for longer lived threads

MAX_CONCURRENT_SOUNDS = 10 # it runs the first X sounds in the queue and ignores the rest

MAX_THREAD_DURATION = 10.0 # number of seconds before a play thread stops taking in new sounds
# NB: this is only how long it pulls in new sounds for, it will continue to play sounds it has until they run out
# so it always lasts a bit longer than the duration depending on sound length

AUTO_FADE_DURATION = 0.02

def square(sample)
  amplitude = 0.05
  frequency = 1000
  half_period = SAMPLE_RATE.to_f / (2 * frequency)

  if (sample.to_f / half_period) % 2 < 1
    amplitude
  else
    -amplitude
  end
end

def sin(sample)
  amplitude = 0.1
  frequency = 1000

  Math.sin((sample * frequency * 2).to_f * Math::PI / SAMPLE_RATE ) * amplitude
end

def saw(sample)
  amplitude = 0.1
  frequency = 1000
  half_period = SAMPLE_RATE.to_f / (2 * frequency)
  upwards = (sample.to_f / half_period) % 2 <= 1
  phase = sample.to_f % half_period

  if upwards
    amplitude * ((phase / half_period) - 0.5) * 2
  else
    amplitude * ((1 - (phase / half_period)) - 0.5) * 2
  end
end

def fade_in(sample, length)
  if sample < 0
    0
  elsif sample < length
    Math.sqrt(sample.to_f/length)
  else
    1
  end
end

def fade_out(sample, max_sample, length)
  samples_from_end = max_sample - sample

  if samples_from_end > length
    1
  elsif sample < max_sample
    Math.sqrt(samples_from_end.to_f/length)
  else
    0
  end
end

# def filter(value)
#   # TODO - if there's any popping at the beginning/end then re-implement a quick fade at the beginning and end

#   if sample < FADE_FILTER_LENGTH
#     value.to_f * fade_in(sample, FADE_FILTER_LENGTH)
#   elsif remaining < FADE_FILTER_LENGTH
#     value.to_f * fade_in(remaining, FADE_FILTER_LENGTH)
#   else
#     value
#   end.clamp(-1,1)
# end

$play_blocks_semaphore = Mutex.new
$play_thread_semaphore = Mutex.new
$play_blocks = Queue.new # array of arrays with each sub array being [&block, total_samples, processed_samples]
$play_thread = nil
$failures = Queue.new
$last_failure_at = Time.now

$any_noises_yet = false

def play(duration = 1, &block)
  if !$any_noises_yet
    $any_noises_yet = true
    # hack to make it start counting from when the noises start, not when the script starts
    $last_failure_at = Time.now
  end

  total_samples = duration * SAMPLE_RATE
  fade_duration = AUTO_FADE_DURATION * SAMPLE_RATE
  faded_sound = Proc.new { |s| fade_in(s, fade_duration) * fade_out(s, total_samples, fade_duration) * block.call(s) }

  $play_blocks.push([faded_sound, total_samples, 0])

  $play_thread_semaphore.synchronize do
    if $play_thread.nil? || !$play_thread.alive?
      $play_thread = start_play_thread
    end
  end
end

def start_play_thread
  Thread.new do
    current_blocks = [] # run with empty blocks at first to prime the buffer
    is_primary = true

    args = %w[play -q -t raw -b 32 -r] + [SAMPLE_RATE.to_s] + %w[-c 1 -e floating-point --endian little - -t alsa]
    Open3.popen2(*args) do |stdin, stdout, status|
      samples_per_batch = (SAMPLE_RATE.to_f * BATCH_LENGTH).ceil
      start = Time.now
      batches_written = 0
      keep_running = true
      linger_remaining = LINGER_TIMEOUT
      has_slept = false

      reverb_delay = 0.18
      reverb_sample_count = reverb_delay*SAMPLE_RATE
      reverb = [0]*reverb_sample_count
      reverb_index = 0
      reverb_fade_in = SAMPLE_RATE * 100

      while true
        batch = []
        samples_per_batch.times do |i|
          val = 0
          current_blocks.each do |el|
            if el[2] + i < el[1]
              val += el[0].call(el[2] + i)
            end
          end

          val += reverb[reverb_index]

          val = val.clamp(-1,1)

          batch << val
          reverb << val * 0.7 * fade_in(Time.now - $last_failure_at, 500)

          reverb_index+= 1
        end
        stdin.print batch.pack('e*')
        stdin.flush
        batches_written += 1

        current_blocks.each { |el| el[2] += samples_per_batch }

        if is_primary && !$failures.empty?
          while(!$failures.empty? && $failures.pop) do; end
          $last_failure_at = Time.now
        end

        end_of_batch_timing = start + (batches_written * samples_per_batch).to_f / SAMPLE_RATE
        start_next_batch_by = end_of_batch_timing - NEXT_BATCH_HEAD_START

        sleep_for = start_next_batch_by - Time.now
        if sleep_for > 0
          has_slept = true
          sleep (sleep_for)
        end

        current_blocks.reject! { |_, total_samples, processed_samples| processed_samples >= total_samples }

        if Time.now - start > MAX_THREAD_DURATION && is_primary
          is_primary = false
          $play_thread_semaphore.synchronize do
            $play_thread = nil
          end
        end

        if is_primary && has_slept && !$play_blocks.empty?
          while current_blocks.length < MAX_CONCURRENT_SOUNDS && !$play_blocks.empty? do
            current_blocks.push($play_blocks.shift)
          end
        end

        if current_blocks.any?
          linger_remaining = LINGER_TIMEOUT
        elsif (linger_remaining -= BATCH_LENGTH) <= 0
          # puts "killing"
          # STDOUT.flush
          if is_primary
            $play_thread_semaphore.synchronize do
              $play_thread = nil # NB: for some reason this is necessary to avoid closing it on freshly added blocks
            end
            # It's awkward to reproduce though, need to start filling out some kind of test harness to check it in extreme scenarios
            # Update - My guess is there's a delay between exiting out of a sync and a thread registering as dead
          end
          Thread.exit
        end
      end
    end
  end
end

def white(str)
  "\033[36m#{str}\033[0m"
end

def cyan(str)
  "\033[37m#{str}\033[0m"
end

def show(samples, width=200, &block)
  max = 0

  samples.times do |s|
    max = [(block.call(s)).abs,max].max
  end

  scale = width.to_f/max

  samples.times do |s|
    val = ((block.call(s)) * scale)
    pos = val > 0

    val = val.abs
    str = "#" * val.floor
    if val % 1 > 0.5
      str+= ":"
    end
    puts(pos ? white(str) : cyan(str) )
  end
end

# thanks! https://stackoverflow.com/a/6178290
class RandomGaussian
  def initialize(mean, stddev, rand_helper = lambda { Kernel.rand })
    @rand_helper = rand_helper
    @mean = mean
    @stddev = stddev
    @valid = false
    @next = 0
  end

  def rand
    if @valid then
      @valid = false
      return @next
    else
      @valid = true
      x, y = self.class.gaussian(@mean, @stddev, @rand_helper)
      @next = y
      return x
    end
  end

  def self.gaussian(mean, stddev, rand)
    theta = 2 * Math::PI * rand.call
    rho = Math.sqrt(-2 * Math.log(1 - rand.call))
    scale = stddev * rho
    x = mean + scale * Math.cos(theta)
    y = mean + scale * Math.sin(theta)
    return x, y
  end
end

def gaus(mean, stddev)
  RandomGaussian.new(mean, stddev).rand
end

#play(5) { |t| square(t) }

# nice soft fade in
# play(1) { |t| fade_in(t, SAMPLE_RATE) * sin(t*2) * 2 + square(t)/2 }


# was trying to make a coin blip noise but ended up with a chirp
# t**1.1 - slowly increase the base frequency
# 3*(t%3000)**1.05 - more quickly increase the frequency, but start over every 3000 samples
# adding them together makes a series of ever higher (first part) ramps (second part)
# play (0.3) { |t| sin(t**1.1+3*(t%3000)**1.05) }

# tried to make a mouth popping noise based on sound analysis of a recorded mouth pop
# sadly, doesn't really sound anything like a mouth pop and the 13k part is just awful
# l=0.1
# pl = Proc.new do
# play(l/4) {|s| sin(s.to_f * 500 / 1000) * ((s.to_f/SAMPLE_RATE/(l/4))**2 - 1)**2 }
# play(l) {|s| sin(s.to_f * 1200 / 1000) * (0.5+0.5*((s.to_f/SAMPLE_RATE/l)**2 - 1)**2) }
# play(l) {|s| sin(s.to_f * 13000 / 1000) * (4*Math.sin((s.to_f/SAMPLE_RATE/l)**0.3 * 18) / (s/SAMPLE_RATE/l + 2)**2).clamp(0,1) }
# end

# TODO - make everything (except show) operate in seconds, samples is too confusing and brittle
# TODO - reverb with variable delay and feedback

if ARGV[0] == "c"
  binding.irb
elsif ARGV.empty?
  ARGF.each_char do |c|
    case c
    when '·'
      r=gaus(0.0,0.025)
      play (0.2) { |t| sin(t**1.1+3*(t)**(1.01 + r)) }
    when '¤'
      r=gaus(0.0,0.03)
      play (0.5) { |t| saw(16.0*t.to_f**(0.8 + r + t.to_f / SAMPLE_RATE / 20)) }
    when 'ƒ'
      $failures.push(true)
      r=gaus(0.0,0.03)
      play (2) { |t| square(t.to_f**0.78 - 200 * Math.sin(t.to_f**(0.5 + r) * 2000 / SAMPLE_RATE * Math::PI)) }
    end
    print c
  end
else
  raise "Invalid arguments #{ARGV.inspect}"
end
