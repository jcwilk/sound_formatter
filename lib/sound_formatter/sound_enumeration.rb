# frozen_string_literal: true

module SoundFormatter::SoundEnumeration
  refine Enumerable do
    def lock
      Enumerator.new do |y|
        self.each { |el| y << el }
      end
    end
  end
end
