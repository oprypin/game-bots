require "stumpy_png"
require "x_do"


STACKS_X = (0...480).step(82).to_a
STACKS_Y = (0...500).step(16).to_a


alias ImageHash = Array({Int32, Int32})
alias Card = Int32

def hash_at(img, x, y) : ImageHash
  pixels = ImageHash.new
  (y+2...y+9).each do |yy|
    (x+2...x+11).each do |xx|
      if img[xx, yy].to_rgb8.all? &.== 255
        pixels << {xx-x, yy-y}
      end
    end
  end
  pixels
end


def learn(img, sample_file)
  hash_to_card = {} of ImageHash => Card
  inputs = File.read(sample_file).split.each

  STACKS_Y.first(6).each do |y|
    STACKS_X.each do |x|
      hsh = hash_at(img, x, y)
      input = inputs.next.as(String)
      hash_to_card[hsh] = Card.new(input.to_i)
    end
  end

  hash_to_card
end

HASH_TO_CARD = learn(StumpyPNG.read("sample.png"), "sample.txt")

def card_at(img, x, y) : Card?
  hash = hash_at(img, x, y)
  HASH_TO_CARD[hash]?
end


class State
  property stacks : Hash(Int32, Array(Card)) = STACKS_X.each_index.map { |i| {i, [] of Card } }.to_h
  property cheat = Set(Int32).new

  def_equals_and_hash stacks.values.to_set, cheat
  def_clone

  property score = 0

  def take_stack(si : Int32, start : Int32) : Array(Card)
    stack = stacks[si]
    if stack[start - 1]? != stack[start] + 1
      self.score += 50
    end
    cheat.delete(si)
    stack.delete_at(start..-1)
  end

  def put_stack(si : Int32, cards : Array(Card))
    stack = stacks[si]
    if stack[-1]? != cards[0] + 1
      self.score -= 50
      cheat.add(si) unless stack.empty?
    end
    stack.concat cards
  end

  def collapse(si : Int32)
    stacks.delete(si)
    cheat.delete(si)
    self.score += 200
  end

  def good?(si : Int32) : Bool
    !cheat.includes?(si) && stacks.has_key?(si)
  end

  def good?(si : Int32, card : Card) : Bool
    good?(si) && (stacks[si].empty? || stacks[si][-1] == card + 1)
  end

  def clone
    cl = clone
    {cl, with cl yield}
  end

  def to_s(io)
    {stacks.each_value.map(&.size).max, 11}.max.times do |i|
      STACKS_X.each_index do |si|
        if (stack = stacks[si]?)
          io << (stack.fetch(i) { ' ' }) << ' '
        else
          io << (i == 0 ? '#' : ' ') << ' '
        end
      end
      io << '\n'
    end
  end
end


def init(img)
  state = State.new

  STACKS_X.each_with_index do |x, si|
    STACKS_Y.each do |y|
      card = card_at(img, x, y) || break
      state.stacks[si] << card
    end
  end

  state.to_s(STDERR)
  total_cards = state.stacks.values.map(&.size).sum
  raise "#{total_cards} < 36 - not enough cards." if total_cards < 36
  state
end


def solve(state)
  empty = [] of { {Int32, Int32}, {Int32, Int32} } | Nil
  todo = [state]
  solutions = {state => empty.dup}

  until todo.empty?
    state = todo.max_by &.score

    if rand(500) == 0
      state.to_s(STDERR)
      STDERR << todo.size << "      \r"
      STDERR.flush
    end
    todo.delete state
    step(state) do |s, sol|
      unless solutions.has_key? s
        todo << s
        sols = solutions[state].dup
        sols << sol
        solutions[s] = sols
        if s.stacks.each_value.all? &.empty?
          s.to_s(STDERR)
          return solutions[s]
        end
      end
    end
    solutions[state] = empty
  end
end


def step(state)
  state.stacks.each do |si, stack|
    if stack.size == 9 && stack.each_cons(2, true).all? { |(a, b)| a == b + 1 }
      yield state.clone {
        collapse(si)
        nil
      }
      return
    end
  end

  state.stacks.each do |si, stack|
    prev = nil
    (0...stack.size).reverse_each do |ci|
      c = stack[ci]

      if prev && c != prev + 1
        break
      end

      state.stacks.each do |osi, ostack|
        next if osi == si
        if state.good?(osi, c) || state.good?(osi) && !prev && state.good?(si)
          yield state.clone {
            put_stack(osi, take_stack(si, ci))
            { {STACKS_X[si], STACKS_Y[ci]}, {STACKS_X[osi], STACKS_Y[ostack.size]} }
          }
        end
      end

      prev = c
    end
  end
end



filename = ARGV.fetch(0) {
  `import -window root screenshot.png`
  "screenshot.png"
}

img = StumpyPNG.read(filename)

m = {img.width, img.height}.min
poss = Array({Int32, Int32}).new
(0...m).each do |a|
  poss.clear
  (0..a).each do |x|
    y = a - x
    if img[x, y].to_rgb8.all? &.== 255
      poss << {x, y}
    end
  end
  if poss.size == 3
    break
  end
end
sx = poss.map(&.[0]).min
sy = poss.map(&.[1]).min
zoom = (poss.map(&.[0]).max - sx) // 2

img = StumpyCore::Canvas.new((img.width - sx) // zoom, (img.height - sy) // zoom) { |x, y|
  img[sx + x * zoom, sy + y * zoom]
}

solution = solve(init(img))
if !solution
  STDERR.puts "Unsolvable"
  exit 1
end


if ARGV.empty?
  window = XDo.new.active_window

  solution.each do |step|
    if step
      x, y = step[0].as(Tuple)
      x, y = sx + x*zoom, sy + y*zoom
      window.move_mouse(x+5, y+5)
      sleep 0.05
      window.mouse_down(:left)
      sleep 0.05
      window.mouse_up(:left)
      sleep 0.05

      x, y = step[1].as(Tuple)
      x, y = sx + x*zoom, sy + y*zoom
      window.move_mouse(x+5, y+5)
      sleep 0.05
      window.mouse_down(:left)
      sleep 0.05
      window.mouse_up(:left)
      sleep 0.2
    else
      sleep 0.25
    end
  end
end
