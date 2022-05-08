# frozen_string_literal: true

module SoundFormatter::SoundEnumeration
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

    def match_laziness(comp)
      comp.kind_of?(Enumerator::Lazy) ? lazy : self
    end
  end
end
