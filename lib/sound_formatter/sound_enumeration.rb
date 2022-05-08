# frozen_string_literal: true

module SoundFormatter::SoundEnumeration
  DEFAULT_SAMPLE_RATE = 41_000

  class << self
    attr_writer :sample_rate

    def sample_rate
      @sample_rate || DEFAULT_SAMPLE_RATE
    end
  end

  refine Enumerable do
    def lock
      source = each # keep a copy of the enumerator separate so it can't be rolled back
      Enumerator.new do |y|
        loop do
          y << source.next
        end
      end.match_laziness(self)
    end

    def then(enum = false, &block)
      enums = []
      enums.push(enum) if enum
      enums.push(Enumerator.new { block.call }) if block_given?

      raise ArgumentError, "No behavior given to #then!" if enums.empty?

      chain(*enums).match_laziness(self)
    end

    def regulate(duration: 1.0/40)
      sample_count = (duration.to_f * SoundFormatter::SoundEnumeration.sample_rate).ceil
      scale = 1.0
      downstep = 1 - 1.0 / SoundFormatter::SoundEnumeration.sample_rate

      lazy.map do |sample|
        ret = sample * scale
        if ret > 1
          scale = 1 / sample
          ret = 1.0
        elsif scale < 1
          scale/= downstep
        else
          scale = 1.0
        end
        ret
      end.match_laziness(self)
    end

    def match_laziness(comp)
      return self unless kind_of?(Enumerator::Lazy) ^ comp.kind_of?(Enumerator::Lazy) # they match, skip it

      kind_of?(Enumerator::Lazy) ? eager : lazy # they don't match, invert it
    end
  end
end
