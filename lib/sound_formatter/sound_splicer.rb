# frozen_string_literal: true

class SoundFormatter::SoundSplicer
  include Enumerable

  def initialize
    @active_enumerators_store = {}
    rebuild
  end

  def splice(enumerator)
    uuid = SecureRandom.uuid
    active_enumerators_store[uuid] = enumerator.chain(Enumerator.new do
      active_enumerators_store.delete(uuid)
      rebuild
    end).chain(Enumerator.produce { 0.0 })
    rebuild
  end

  def each(&block)
    enum = Enumerator.new do |y|
      loop { y << active_enum.next }
    end

    return enum unless block_given?

    enum.each(&block)
  end

  private

  def rebuild
    active_enums = active_enumerators_store.values
    if active_enums.empty?
      @active_enum = Enumerator.new {}.lazy
      return
    end

    if active_enums.size == 1
      @active_enum = active_enums.first.lazy
      return
    end

    base, *extra = active_enums

    @active_enum = base.lazy.zip(*extra).map(&:sum)
  end

  attr_reader :active_enum, :active_enumerators_store
end
