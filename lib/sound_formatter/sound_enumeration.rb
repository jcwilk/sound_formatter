# frozen_string_literal: true

module SoundFormatter::SoundEnumeration
  refine Enumerable do
    def lock
      source = each # keep a copy of the enumerator separate so it can't be rolled back
      Enumerator.new do |y|
        loop do
          y << source.next
        end
      end.lazy
    end
  end
end
