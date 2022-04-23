#!/usr/bin/env ruby

$stdout.sync = true

while(true) do
  sleep(rand())
  print('·')
  print('ƒ') if rand < 0.05
  print('¤') if rand < 0.05
end
