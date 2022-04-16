#!/usr/bin/env ruby

require 'rubygems'
require 'open3'
require 'irb'
require 'securerandom'
require 'benchmark'

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

MAX_BUFFER_SIZE = 0.3

SAMPLES_PER_START = 0.07 * SAMPLE_RATE

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

class ForwardOnlyEnumerator
  include Enumerable

  def initialize(enumerator)
    @enum = enumerator
  end

  def each
    if block_given?
      loop do
        yield @enum.next
      end
    else
      enum_for(:each)
    end
  end
end

class SoundEnumerator
  include Enumerable

  def initialize(duration, &block)
    step = 1.0 / SAMPLE_RATE
    sample_count = (duration * SAMPLE_RATE).floor
    @raw_enum = 0.0.step(by: step).lazy.map(&block).take(sample_count)
  end

  def play
    enum = @raw_enum.eager

    return enum unless block_given?

    enum.each { |sample| yield sample }
  end
end

class SoundSplicer
  def initialize
    @active_enumerators_store = {}
  end

  def add(enumerator)
    uuid = SecureRandom.uuid
    active_enumerators_store[uuid] = enumerator.chain(Enumerator.new do
      active_enumerators_store.delete(uuid)
    end).chain(0.0.step(by: 0)).each
  end

  def play
    if block_given?
      while(!active_enumerators.empty?) do
        yield active_enumerators.sum(&:next)
      end
    else
      enum_for(:play)
    end
  end

  def active_enumerators
    active_enumerators_store.values
  end

  private

  attr_reader :active_enumerators_store
end

class TapeLoop
  def initialize
    @loop = [0.0] * (REVERB_DELAY * SAMPLE_RATE).to_i
    @index = 0
  end

  def play
    if block_given?
      loop do
        @index = (@index + 1) % @loop.size
        yield @loop[@index]
      end
    else
      enum_for(:play)
    end
  end

  def write(sample)
    @loop[@index] = sample * 0.7
  end
end

class Channel
  include Enumerable

  def initialize
    @splicer = SoundSplicer.new
    @tape_loop = TapeLoop.new
    add(tape_loop)
    @splicer_enum = splicer.play
  end

  def add(playable)
    splicer.add(playable.play)
  end

  def play
    if block_given?
      loop do
        yield @splicer_enum.next.tap { |sample| tape_loop.write(sample) }
      end
    else
      enum_for(:play)
    end
  end

  private

  attr_reader :splicer, :tape_loop
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

  def buffer_sample_debt
    elapsed_time = (Time.now - started_at).to_f
    elapsed_samples = (elapsed_time * SAMPLE_RATE).ceil
    extra_samples = (MAX_BUFFER_SIZE * SAMPLE_RATE).ceil

    elapsed_samples + extra_samples - samples_written
  end

  def play(enum)
    buffer = nil
    debt = buffer_sample_debt
    buffer_size = [debt,MAX_SAMPLES_PER_BATCH].min
    # bm = Benchmark.measure do
      buffer = enum.lazy.map { |sample| sample.clamp(-1,1) }.first(buffer_size)
    # end

    # puts ""
    # puts(buffer.size / bm.real)
    # puts buffer.size
    # puts debt

    stdin.print buffer.pack('e*')
    stdin.flush

    @samples_written += buffer.size
  end

  private

  attr_reader :samples_written, :started_at, :stdin, :stdout
end

$last_failure_at = Time.now

$any_noises_yet = false

$channel = Channel.new
$sound_stream = SoundStream.new

# for legacy sound equations because I'm too lazy to convert them to be based on seconds rather than sample index
def play_samples(duration = 1, &block)
  play(duration) { |seconds| block.call((seconds.to_f * SAMPLE_RATE).floor) }
end

def play(duration = 1, &block)
  $channel.add(SoundEnumerator.new(duration, &block))
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
        play_samples (0.2) { |i| sin(i**1.1+3*(i)**(1.01 + r)) }
      when '¤'
        r=gaus(0.0,0.03)
        play_samples (0.5) { |i| saw(16.0*i.to_f**(0.8 + r + i.to_f / SAMPLE_RATE / 20)) }
      when 'ƒ'
        $failures.push(true)
        r=gaus(0.0,0.03)
        play_samples (2) { |i| square(i.to_f**0.78 - 200 * Math.sin(i.to_f**(0.5 + r) * 2000 / SAMPLE_RATE * Math::PI)) }
      else
        #puts c.bytes.inspect
        #next
      end
      print c
    end

    $sound_stream.play($channel.play)
  end
else
  raise "Invalid arguments #{ARGV.inspect}"
end
