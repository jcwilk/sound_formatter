#!/usr/bin/env ruby

require 'rubygems'
#require 'bundler/setup'
#Bundler.require(:default)
require 'open3'
require 'irb'

JSON_START = "↦"
JSON_END = "↤"

# start simple,
# each function expects the time index in seconds and returns the corresponding wave value

SAMPLE_RATE = 41_000 # samples per second
# Currently the sample calculation block and the sound functions all work based on samples
# so changing this value will pitch-shift any existing song scripts
# Still haven't decided if I want to make everything run on seconds or not...
# Seems like it's a missed opportunity to not calculate based on the exact sample integer,
# even if it's almost always converted to a float right awaypipeline keeps ALSA happy

FADE_FILTER_LENGTH = SAMPLE_RATE * 0.1 # samples (here in seconds) to fade in/out on every sound to avoid clicks
# NB: Not currently used, it's quite difficult to anticipate the end of a set of sounds efficiently

MAX_CONCURRENT_SOUNDS = 10 # it runs the first X sounds in the queue and the rest have to wait

AUTO_FADE_DURATION = 0.02

MAX_BUFFER_SIZE = 0.1

SAMPLES_PER_START = 0.07 * SAMPLE_RATE

REVERB_DELAY = 0.4

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
  amplitude = 0.07
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

class SoundStream
  def initialize
    args = %w[play -q -t raw -b 32 -r] + [SAMPLE_RATE.to_s] + %w[-c 1 -e floating-point --endian little - -t alsa]
    @stdin, @stdout, _wait_thr = Open3.popen2(*args)
    @samples_written = 0
    @started_at = Time.now
  end

  def close
    stdin.close
    stdout.close
  end

  def buffer_time_debt
    MAX_BUFFER_SIZE + (Time.now - started_at).to_f - samples_written / SAMPLE_RATE
  end

  def play(buffer)
    buffer.map! { |sample| sample.clamp(-1,1) }

    stdin.print buffer.pack('e*')
    stdin.flush

    @samples_written += buffer.size
  end

  private

  attr_reader :samples_written, :started_at, :stdin, :stdout
end

class Channel
  def initialize
    @sound_stream = SoundStream.new
    @queued_blocks = []
    @active_blocks = []
    @samples_until_next = SAMPLES_PER_START
    @tape_loop = TapeLoop.new
  end

  def play(sound_block)
    # if full?
      queued_blocks << sound_block
    # else
    #   active_blocks << sound_block
    # end
  end

  def fill_buffer
    #seconds_needed = [sound_stream.buffer_time_debt,MAX_BUFFER_SIZE].min
    # TODO: Something's screwed up here, if you give it too high a buffer then it works great, but the above line makes it sound like garbage
    seconds_needed = MAX_BUFFER_SIZE

    return if seconds_needed <= 0

    batch = (seconds_needed * SAMPLE_RATE).to_i.times.map do |i|
      if @samples_until_next < i && pending? && !full?
        active_blocks.push(queued_blocks.pop)
        @samples_until_next = i + gaus(SAMPLES_PER_START, SAMPLES_PER_START/2)
      end

      active_blocks.reduce(0) do |acc, el|
        block_index = el[2] + i
        if block_index < el[1]
          acc + el[0].call(block_index)
        else
          acc
        end
      end
    end

    @samples_until_next -= batch.size

    batch = tape_loop.play(batch)

    sound_stream.play(batch)

    active_blocks.each { |el| el[2] += batch.size }
    active_blocks.select! { |_, max, processed| processed < max }
  end

  def active?
    !active_blocks.empty? || pending?
  end

  private

  attr_reader :active_blocks, :queued_blocks, :sound_stream, :tape_loop

  def pending?
    !queued_blocks.empty?
  end

  def full?
    slots_left == 0
  end

  def slots_left
    MAX_CONCURRENT_SOUNDS - active_blocks.size
  end
end

class TapeLoop
  def initialize
    @loop = [0.0] * (REVERB_DELAY * SAMPLE_RATE).to_i
    @index = 0
  end

  def play(input_buffer)
    (0...input_buffer.size).map do |i|
      loop_i = i % @loop.size
      @loop[loop_i] = @loop[loop_i] * 0.5 + input_buffer[i]
    end
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

$last_failure_at = Time.now

$any_noises_yet = false

$channel = Channel.new

def play(duration = 1, &block)
  if !$any_noises_yet
    $any_noises_yet = true
    # hack to make it start counting from when the noises start, not when the script starts
    $last_failure_at = Time.now
  end

  total_samples = duration * SAMPLE_RATE
  fade_samples = AUTO_FADE_DURATION * SAMPLE_RATE
  faded_sound = Proc.new { |s| fade_in(s, fade_samples) * fade_out(s, total_samples, fade_samples) * block.call(s) }

  $channel.play([faded_sound, total_samples, 0])
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

def get_characters
  begin
    ARGF.read_nonblock(16).encode(Encoding::UTF_8, Encoding::UTF_8)
  rescue IO::EAGAINWaitReadable
    #retry
    ""
  end
end

def fill_buffer_until_empty
  while ($channel.active?) do
    puts "filling"
    $channel.fill_buffer
  end
end

# A good spot for scratch space - this will run before the console loads

# 5.times do
#   r=gaus(0.0,0.025)
#   play (0.3) { |t| sin(t**1.1+3*(t)**(1.01 + r)) }
# end

# puts $channel.active?.inspect

# fill_buffer_until_empty

if ARGV[0] == "c"
  binding.irb
elsif ARGV.empty?
  # TODO: need to change this to not block while it's waiting for more characters so we can continue processing samples in the same thread.
  # If we do this then we can get rid of the last bits of threading code and keep it all single-thread. May or may not be able to keep up in that form though...

  tracker = {}

  json_buffer = ""
  reading_json = false

  while(true) do
    get_characters.each_char do |c|
      if reading_json
        if c == JSON_END
          reading_json = false
          process_json(json_buffer)
        else
          json_buffer+= c
        end
        next
      end

      if c == JSON_START
        reading_json = true
        json_buffer = ""
        next
      end

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
      else
        #puts c.bytes.inspect
        #next
      end
      print c
    end

    $channel.fill_buffer
  end
else
  raise "Invalid arguments #{ARGV.inspect}"
end
