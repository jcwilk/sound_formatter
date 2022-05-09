# frozen_string_literal: true

class SoundFormatter::SoundSplitter
  include Enumerable

  def initialize(enumerator)
    @enumerator = enumerator
    @index = 0
    @last_value = 0.0
  end

  def split
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
    end
  end

  private

  attr_reader :enumerator, :index
end
