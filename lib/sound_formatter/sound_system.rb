# frozen_string_literal: true

require_relative './sound_enumeration'

using SoundFormatter::SoundEnumeration

# TODO: try to turn this all into enumerable extensions perhaps? mostly?

class TimedSoundEnumerator
  def initialize(duration, &block)
    step = 1.0 / SAMPLE_RATE
    sample_count = (duration * SAMPLE_RATE).floor

    base_enum = 0.0.step(by: step).lazy.with_index.lock

    if sample_count <= FADE_FILTER_LENGTH
      @raw_enum = 0.0.step(by: step).lazy.take(sample_count)
      return
    end

    fading_in = base_enum.take(FADE_FILTER_LENGTH).map { |s, i| fade_in(i, FADE_FILTER_LENGTH) * block.call(s, i) }
    vanilla = base_enum.take(sample_count - FADE_FILTER_LENGTH).map(&block)

    @raw_enum = DurationFilter.new(fading_in.chain(vanilla).lazy, sample_count: sample_count).play
  end

  def play
    @raw_enum
  end
end

class KillSwitchFilter
  def initialize(enumerator)
    last_sample = nil
    vanilla = enumerator.take_while do |sample|
      if @ending
        last_sample = sample
        false
      else
        true
      end
    end.chain(Enumerator.new { |y| y << last_sample if last_sample })
    fading_out = enumerator.with_index.take(FADE_FILTER_LENGTH).map { |sample, i| fade_out(i, FADE_FILTER_LENGTH, FADE_FILTER_LENGTH) * sample }

    @enum = vanilla.chain(fading_out).lazy
  end

  def end
    @ending = true
  end

  def play
    @enum
  end
end

class DurationFilter
  def initialize(enumerator, sample_count:)
    #sample_count = (duration * SAMPLE_RATE).floor
    if sample_count < FADE_FILTER_LENGTH
      @enum = Enumerator.produce { 0.0 }.lazy.take(sample_count)
      return
    end

    vanilla = enumerator.take(sample_count - FADE_FILTER_LENGTH)
    fading_out = enumerator.with_index.take(FADE_FILTER_LENGTH).map { |sample, i| fade_out(i, FADE_FILTER_LENGTH, FADE_FILTER_LENGTH) * sample }

    @enum = vanilla.chain(fading_out).lazy
  end

  def play
    @enum
  end
end

class ControlledSoundEnumerator
  def initialize(&block)
    step = 1.0 / SAMPLE_RATE
    @raw_enum = Enumerator.produce { 0.0 }.with_index.lock.map do |s, i|
      fade_in(i, FADE_FILTER_LENGTH) * block.call(s, i)
    end
    @killswitch = KillSwitchFilter.new(@raw_enum)
    @raw_enum = @killswitch.play
  end

  def play
    @raw_enum
  end

  def end
    @killswitch.end
  end
end

class SoundSplicer
  def initialize
    @active_enumerators_store = {}
    @active_enumerators = [] # This is to avoid creating an array via Hash#values more than we need to
  end

  def add(enumerator)
    uuid = SecureRandom.uuid
    active_enumerators_store[uuid] = enumerator
      .then {
        active_enumerators_store.delete(uuid)
        @active_enumerators = active_enumerators_store.values
      }.chain(
        0.0.step(by: 0)
      ).lazy
    @active_enumerators = active_enumerators_store.values
  end

  def play
    Enumerator.new do |y|
      while(!active_enumerators.empty?) do
        y << active_enumerators.sum(0.0, &:next)
      end
    end.lazy
  end

  private

  attr_reader :active_enumerators, :active_enumerators_store
end

class SoundSplitter
  def initialize(enumerator)
    @enumerator = enumerator
    @index = 0
    @last_value = 0.0
  end

  def play
    # Possible bug with requiring this to be -1, if set to 0 it triggers a "double resume (FiberError)" - this may be a hint
    # that one of these mechanisms is trying to start enumerating before it's supposed to... but just something to keep in mind,
    # it's still working fine if started at -1 and the only consequence is a possible extra sample of silence at the beginning :shrug:
    our_index = -1
    Enumerator.new do |y|
      loop do
        y << if our_index == @index
            (@last_value = enumerator.next).tap do
              our_index = (@index += 1)
            end
          else
            our_index = @index
            @last_value
          end
      end
    end.lazy
  end

  private

  attr_reader :enumerator, :index
end

class Channel
  def initialize
    @splicer = SoundSplicer.new
    @splitter = SoundSplitter.new(splicer.play.regulate)
  end

  def add(enumerator)
    splicer.add(enumerator)
  end

  # This adds an infinite silent enumerator so if it has nothing to play it will keep playing silence
  # Without this, the channel will stop generating samples and the sound stream buffer will underrun
  # If you *do* want the channel to auto-remove itself from other splicers/channels then don't call this
  def add_silence
    splicer.add(0.0.step(by: 0).lazy)
  end

  def play
    splitter.play
  end

  private

  attr_reader :splicer, :splitter
end

class TapeLoop
  def initialize(feed, delay:, scale:)
    @loop = [0.0] * [(delay * SAMPLE_RATE).floor,1].max
    @feed = feed
    @scale = scale
    @index = 0
  end

  def play
    (0...@loop.size).step.lazy.cycle.zip(feed).map do |index, new_sample|
      ret = @loop[index]
      @loop[index] = new_sample * scale
      ret
    end.lock
  end

  private

  attr_reader :feed, :index, :scale
end

# Reasonably natural-sounding low-pass filter, good for echoes
# AKA Simple Moving Average
class RollingAverageFilter
  def initialize(feed, span:)
    @average = 0.0
    @feed = feed
    @queue = [0.0] * [(span * SAMPLE_RATE).floor,1].max
  end

  def play
    feed.map do |sample|
      queue.push(sample)
      @average += (sample - queue.shift) / queue.size
    end
  end

  private

  attr_reader :average, :feed, :queue
end

# Very weird low-pass filter that makes sounds that are too high pitched fade out as laser-like sounds
# I guess because it kind of turns them into sloppy triangle waves as it forces it to be limited to a specific slope
class DraggingFilter
  def initialize(feed, change_per_second:)
    @feed = feed
    @max_change = change_per_second.to_f / SAMPLE_RATE
    @value = 0.0
  end

  def play
    feed.map do |sample|
      @value += (sample - @value).clamp(-max_change, max_change)
    end
  end

  private

  attr_reader :feed, :max_change, :value
end

# Useful for turning low-pass filters into high-pass filters
class InversionFilter
  def initialize(feed)
    @feed = feed
  end

  def play
    feed.map { |sample| -sample }
  end

  private

  attr_reader :feed
end

class SoundStream
  def initialize
    args = %w[play -q -t raw -b 32 -r] + [SAMPLE_RATE.to_s] + %w[-c 1 -e floating-point --endian little - -t alsa]
    @stdin, @stdout, _wait_thr = Open3.popen2(*args)
    @samples_written = 0
    @started_at = Time.now
    @buffer_samples = (MAX_BUFFER_SIZE * SAMPLE_RATE).ceil
  end

  def close
    stdin.close
    stdout.close
  end

  def buffer_sample_debt
    elapsed_time = (Time.now - started_at).to_f
    elapsed_samples = (elapsed_time * SAMPLE_RATE).ceil

    elapsed_samples + @buffer_samples - samples_written
  end

  def consume(enum)
    debt = buffer_sample_debt
    buffer_size = [debt,MAX_SAMPLES_PER_BATCH].min
    buffer = enum.first(buffer_size)

    stdin.print buffer.pack('e*')
    stdin.flush

    @samples_written += buffer.size
  end

  private

  attr_reader :samples_written, :started_at, :stdin, :stdout
end

class RecordingStream
  def initialize
    args = %w[rec -q -t raw -r] + [SAMPLE_RATE.to_s] + %w[-c 1 -e s -]
    @stdin, @stdout, _wait_thr = Open3.popen2(*args)
    @samples_read = 0
    @started_at = Time.now
    @buffer_samples = (MAX_BUFFER_SIZE * SAMPLE_RATE).ceil
  end

  def close
    stdin.close
    stdout.close
  end

  def play
    return enum_for(:play) unless block_given?

    buffer = []

    loop do
      buffer.push(*read_samples) if buffer.empty?
      yield buffer.shift || 0.0
    end
  end

  private

  def read_samples
    begin
      stdout.read_nonblock(16)
    rescue IO::EAGAINWaitReadable
      ""
    end.unpack('s*').map { |sample| sample.to_f / 32768 }
  end

  attr_reader :samples_written, :started_at, :stdin, :stdout
end