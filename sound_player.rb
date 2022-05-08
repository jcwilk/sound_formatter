#!/usr/bin/env ruby

require 'rubygems'
require 'open3'
require 'irb'
require 'securerandom'
require 'benchmark'

require './lib/sound_formatter'

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

FADE_FILTER_LENGTH = SAMPLE_RATE * 0.02 # samples (here in seconds) to fade in/out on every sound to avoid clicks

MAX_BUFFER_SIZE = 0.3

REVERB_DELAY = 0.2

MAX_SAMPLES_PER_BATCH = 2000


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
    0.0
  elsif sample < length
    Math.sqrt(sample.to_f/length)
  else
    1.0
  end
end

def fade_out(sample, max_sample, length)
  samples_from_end = max_sample - sample

  if samples_from_end > length
    1.0
  elsif sample < max_sample
    Math.sqrt(samples_from_end.to_f/length)
  else
    0.0
  end
end



$last_failure_at = Time.now

$any_noises_yet = false

# long_tape_channel = Channel.new
# long_tape_channel.add_input_feed($input_channel.add_output_feed)
# long_tape_loop = TapeLoop.new(long_tape_channel.add_output_feed, delay: 5, scale: 0.6)
# long_tape_channel.add_input_feed(long_tape_loop.play)

# short_tape_channel = Channel.new
# short_tape_channel.add_input_feed(long_tape_channel.play)
# short_tape_loop = TapeLoop.new(short_tape_channel.add_output_feed, delay: 0.1, scale: 0.85)
# short_tape_channel.add_input_feed(short_tape_loop.play)

# $output_channel = SoundSplicer.new
# $output_channel.add_input_feed($input_channel.play)
# $output_channel.add_input_feed(short_tape_channel.play)




using SoundFormatter::SoundEnumeration

$input_channel = Channel.new
$input_channel.add_silence

#filter = InfluenceFilter.new($input_channel.play, influence: 5_000)
#filter = DraggingFilter.new($input_channel.play, change_per_second: 500)
#filter = RollingAverageFilter.new($input_channel.play, span: 1.0/3_000)

# with inversion, low-pass becomes high-pass
#inversion = InversionFilter.new(filter.play)

#$switched_filter = KillSwitchFilter.new(filter.play)

filter_channel = Channel.new
#filter_channel.add($input_channel.play)
#filter_channel.add($switched_filter.play)
filter_channel.add($input_channel.play.ema_low_pass(influence: 5_000))

echo = TapeLoop.new(filter_channel.play, delay: 1.723, scale: 0.66667)
reverb = TapeLoop.new(filter_channel.play, delay: 0.15812, scale: 0.3)

# TODO: put the regulator in a different place so it's not downscaling innocent bystanders?

$input_channel.add(echo.play)
$input_channel.add(reverb.play)

$output_enum = filter_channel.play

# outgoing_delay = TapeLoop.new($input_channel.play, delay: 2, scale: 0.4)

# distant_channel = Channel.new
# distant_channel.add(outgoing_delay.play)

# distand_reverb = TapeLoop.new(distant_channel.play, delay: 0.05, scale: 0.6)
# distant_channel.add(distand_reverb.play)

# incoming_delay = TapeLoop.new(distant_channel.play, delay: 2, scale: 1.4)
# $input_channel.add(incoming_delay.play)

# $output_enum = $input_channel.play





# long_tape_input_channel = Channel.new
# long_tape_input_channel.add($input_channel.play)

# long_tape_output_channel = Channel.new
# #long_tape_input_channel.add(long_tape_output_channel.play)

# long_tape_loop = TapeLoop.new(long_tape_input_channel.play, delay: 2, scale: 0.4)
# long_tape_output_channel.add(long_tape_loop.play)



# # long_tape_output_channel.add($input_channel.play)
# # long_tape_loop = TapeLoop.new(long_tape_output_channel.add_output_feed, delay: 5, scale: 0.6)
# # long_tape_output_channel.add(long_tape_loop.play)

# short_tape_channel = Channel.new
# short_tape_channel.add(long_tape_output_channel.play)

# short_tape_loop = TapeLoop.new(short_tape_channel.play, delay: 0.1, scale: 0.5)
# short_tape_channel.add(short_tape_loop.play)

# long_tape_input_channel.add(short_tape_channel.play)

# #$input_channel.add($input_channel.add_output_feed)
# #tape_loop = TapeLoop.new($input_channel.add_output_feed, delay: REVERB_DELAY, scale: 0.6)
# #$input_channel.add(tape_loop.play)

# $output_channel = Channel.new
# $output_channel.add(short_tape_channel.play)
# $output_channel.add($input_channel.play)

# $output_enum = $output_channel.play

$sound_stream = SoundStream.new

def play(duration = 1, &block)
  $input_channel.add(TimedSoundEnumerator.new(duration, &block).play)
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

if ARGV[0] == "c"
  # A good spot for scratch space - this will run before the console loads

  # 5.times do
  #   r=gaus(0.0,0.025)
  #   play (0.3) { |t| sin(t**1.1+3*(t)**(1.01 + r)) }
  # end

  # puts $channel.active?.inspect

  # $sound_stream

  binding.irb
elsif ARGV[0] == "r"
  $input_channel.add(RecordingStream.new.play)
  loop do
    $sound_stream.consume($output_enum)
  end
  puts "done"
elsif ARGV.empty?
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
        play (0.2) { |_s, i| sin(i**1.1+2*(i)**(1.01 + r)) }

        # if $enum
        #   $enum.end
        # end
        # $enum = ControlledSoundEnumerator.new { |_s, i| sin(i**1.1+3*(i)**(1.01 + r)) }
        # $input_channel.add($enum.play)
      when '¤'
        r=gaus(0.0,0.03)
        play (0.5) { |_s, i| saw(16.0*i.to_f**(0.8 + r + i.to_f / SAMPLE_RATE / 20)) }
      when 'ƒ'
        #$switched_filter.end
        r=gaus(0.0,0.03)
        play (2) { |_s, i| square(i.to_f**0.78 - 200 * Math.sin(i.to_f**(0.5 + r) * 2000 / SAMPLE_RATE * Math::PI)) }
      else
        #puts c.bytes.inspect
        #next
      end
      print c
    end

    $sound_stream.consume($output_enum)
  end
else
  raise "Invalid arguments #{ARGV.inspect}"
end
