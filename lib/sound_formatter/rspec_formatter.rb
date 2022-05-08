# frozen_string_literal: true

require "rspec/core/formatters/base_text_formatter"

class SoundFormatter::RSpecFormatter < RSpec::Core::Formatters::BaseTextFormatter
  RSpec::Core::Formatters.register self, :example_passed, :example_pending, :example_failed

  JSON_START = "↦"
  JSON_END = "↤"
  # Outputting JSON like this: ↦{a: 1}↤ will get parsed by `sound_player.rb` if you want to send more detailed events

  def example_passed(_notification)
    output.print RSpec::Core::Formatters::ConsoleCodes.wrap('·', :success)
  end

  def example_pending(_notification)
    output.print RSpec::Core::Formatters::ConsoleCodes.wrap('¤', :pending)
  end

  def example_failed(_notification)
    output.print RSpec::Core::Formatters::ConsoleCodes.wrap('ƒ', :failure)
  end
end
