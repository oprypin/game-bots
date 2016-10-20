require "colorize"
require "stumpy_png"

enum Suit
  Red
  Green
  Black
end

record Card, suit : Suit?, number : Int32? do
  def to_s(io)
    color = case suit
    when Suit::Red;   :red
    when Suit::Green; :green
    when Suit::Black; :black
    else;             :yellow
    end
    if number
      io << number.colorize.fore(color)
    else
      io << " ".colorize.back(color)
    end
  end

  def dragon?
    suit && !number
  end
  def flower?
    !suit && !number
  end
end


TOP_Y = 135

FREE = 414.step(800, 152).to_a.map { |x| {x, TOP_Y} }
FLOWER = {982, TOP_Y}
FOUND = 1174.step(1500, 152).to_a.map { |x| {x, TOP_Y} }
BTN = 160.step(350, 83).to_a.map { |y| {888, y} }

STACKS_X = 414.step(1500, 152).to_a
STACKS_Y = 399.step(900, 31).to_a


alias ImageHash = Array({Int32, Int32, {UInt8, UInt8, UInt8}})

def hash_at(img, x, y) : ImageHash
  pixels = ImageHash.new
  (y...y+18).each do |yy|
    (x...x+12).each do |xx|
      px = img[xx, yy].to_rgb8
      if px.any? &.< 70
        pixels << {xx-x, yy-y, px}
      end
    end
  end
  pixels
end


def learn(img, sample_file)
  hash_to_card = {} of ImageHash => Card
  inputs = File.read(sample_file).split.each

  STACKS_Y.first(5).each do |y|
    STACKS_X.each do |x|
      hsh = hash_at(img, x, y)
      input = inputs.next.as(String)

      suit = {'r' => Suit::Red, 'g' => Suit::Green, 'b' => Suit::Black}.fetch(input[0].downcase, nil)
      number = input[1..-1].to_i if input.size > 1

      hash_to_card[hsh] = Card.new(suit, number)
    end
  end

  hash_to_card
end

HASH_TO_CARD = learn(StumpyPNG.read("sample.png"), "sample.txt")

def card_at(img, x, y)
  HASH_TO_CARD.fetch(hash_at(img, x, y), nil)
end


class State
  property stacks = StaticArray(Array(Card), 8).new { [] of Card }
  property free = StaticArray(Card?, 3).new(nil)
  property flower : Card? = nil
  property found = StaticArray(Card?, 3).new(nil)

  def_equals_and_hash stacks, free, flower, found
  def_clone

  property score = 0
  @found_pos = Array(Suit).new

  def put_free(i : Int32?, card : Card?) : Int32
    i ||= (self.free.index(nil) || raise "")
    raise "" if self.free[i]
    if card
      self.free[i] = card
      self.score -= 40
    else
      self.free[i] = Card.new(nil, nil)
      self.score += 1000
    end
    i
  end

  def take_free(i : Int32) : Card
    card = self.free[i].not_nil!
    self.free[i] = nil
    self.score += 40
    card
  end

  def put_flower(card : Card)
    raise "" unless card.flower?
    self.flower = card
    self.score += 200
  end

  def put_found(card : Card, init = false)
    number = card.number.not_nil!
    suit = card.suit.not_nil!
    if init
      raise "" if self.found[suit.to_i]
    else
      raise "" unless number - 1 == self.found_number(suit)
    end
    self.found[suit.to_i] = card
    self.score += 100
    self.found_pos(suit)
  end

  def take_stack(i : Int32, start : Int32) : Array(Card)
    r = self.stacks[i][start..-1]
    self.stacks[i].delete_at(start..-1)
    r
  end

  def take_card(i : Int32) : Card
    r = self.stacks[i][-1]
    self.stacks[i].delete_at(-1)
    r
  end

  def put_stack(i : Int32, cards : Array(Card))
    self.stacks[i].concat cards
    #self.score += 1
  end

  def found_pos(suit : Suit) : Int32
    if !@found_pos.includes? suit
      @found_pos << suit
    end
    @found_pos.index(suit).not_nil!
  end

  def found_number(suit : Suit) : Int32
    if (card = found[suit.to_i])
      card.number.not_nil!
    else
      0
    end
  end

  def clone
    cl = clone
    {cl, with cl yield}
  end

  def to_s(io)
    self.free.each do |c|
      io << (c || ' ') << ' '
    end
    io << ' ' << (self.flower || ' ') << ' '
    @found_pos.each do |suit|
      io << ' ' << (self.found[suit.to_i] || ' ')
    end
    io << "\n\n"

    {self.stacks.map(&.size).max, 11}.max.times do |i|
      self.stacks.each do |stack|
        io << (stack.at(i) { ' ' }) << ' '
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

  FREE.each_with_index do |pos, i|
    if (card = card_at(img, *pos))
      state.put_free(i, card)
    end
  end

  if (card = card_at(img, *FLOWER))
    state.put_flower(card)
  end

  FOUND.each do |pos|
    9.times do |dy|
      if (card = card_at(img, pos[0], pos[1]-dy))
        state.put_found(card, init: true)
        break
      end
    end
  end

  state.to_s(STDERR)
  state
end


def solve(img)
  state = init(img)
  empty = [] of ({Int32, Int32} | { {Int32, Int32}, {Int32, Int32} } | Nil)
  todo = [state]
  solutions = {state => empty.dup}

  until todo.empty?
    state = todo.max_by &.score

    if rand(100) == 0
      if todo.size > 5000
        state.to_s(STDERR) if rand(10) == 0
      end
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
        if s.stacks.all? &.empty?
          return solutions[s]
        end
      end
    end
    solutions[state] = empty
  end
end


def step(state)
  put_found(state, only_auto: true) do |s, sol|
    yield s, sol
    return
  end

  Suit.values.each do |suit|
    if state.free.any? { |c| !c || c.dragon? && c.suit == suit }
      count = 0

      state.stacks.each do |stack|
        next if stack.empty?
        if stack.last.dragon? && stack.last.suit == suit
          count += 1
        end
      end
      state.free.each do |c|
        next unless c
        if c.dragon? && c.suit == suit
          count += 1
        end
      end

      if count == 4
        yield state.clone {
          state.stacks.each_with_index do |stack, si|
            next if stack.empty?
            if stack.last.dragon? && stack.last.suit == suit
              take_card(si)
            end
          end
          state.free.each_with_index do |c, ci|
            next unless c
            if c.dragon? && c.suit == suit
              take_free(ci)
            end
          end

          put_free(nil, nil)
          BTN[suit.to_i]
        }
      end
    end
  end

  put_found(state) do |s, sol|
    yield s, sol
  end

  state.stacks.each_with_index do |stack, si|
    next if stack.empty?
    last = stack.last
    next unless last.dragon?

    state.stacks.each_with_index do |ostack, osi|
      if ostack.empty?
        yield state.clone {
          put_stack(osi, [take_card(si)])
          { {STACKS_X[si], STACKS_Y[stack.size-1]}, {STACKS_X[osi], STACKS_Y[ostack.size]} }
        }
      end
    end
  end

  state.stacks.each_with_index do |stack, si|
    next if stack.empty?
    prev = nil
    (0...stack.size).reverse_each do |ci|
      c = stack[ci]

      break unless (number = c.number) && (suit = c.suit)
      if prev
        break unless number - 1 == prev.number
        break unless suit != prev.suit
      end

      state.stacks.each_with_index do |ostack, osi|
        next if osi == si
        if (ostack.empty? && ci > 0) || (!ostack.empty? && (onumber = ostack.last.number) && number + 1 == onumber && suit != ostack.last.suit)
          yield state.clone {
            put_stack(osi, take_stack(si, ci))
            { {STACKS_X[si], STACKS_Y[ci]}, {STACKS_X[osi], STACKS_Y[ostack.size]} }
          }
        end
      end

      prev = c
    end
  end

  if state.free.any? &.nil?
    state.stacks.each_with_index do |stack, si|
      next if stack.empty?
      last = stack.last
      next if last.flower?
      yield state.clone {
        fi = put_free(nil, take_card(si))
        { {STACKS_X[si], STACKS_Y[stack.size-1]}, FREE[fi] }
      }
    end
  end
end

def put_found(state, only_auto = false)
  state.stacks.each_with_index do |stack, si|
    next if stack.empty?
    last = stack.last
    if (number = last.number) && (suit = last.suit)
      if number - 1 == state.found_number(suit)
        if (auto = check_auto(state, last)) || !only_auto
          yield state.clone {
            fi = put_found(take_card(si))
            auto ? nil : { {STACKS_X[si], STACKS_Y[stack.size-1]}, FOUND[fi] }
          }
        end
      end
    elsif last.flower?
      if !only_auto
        yield state.clone {
          put_flower(take_card(si))
          nil
        }
      end
    end
  end

  state.free.each_with_index do |card, i|
    next unless card
    if (number = card.number) && (suit = card.suit)
      if number - 1 == state.found_number(suit)
        if (auto = check_auto(state, card)) || !only_auto
          yield state.clone {
            fi = put_found(take_free(i))
            auto ? nil : {FREE[i], FOUND[fi]}
          }
        end
      end
    end
  end
end

def check_auto(state, check)
  state.stacks.each do |stack|
    stack.each do |card|
      if (number = card.number) && number < check.number.not_nil! && number > 1# && state.found_number(card.suit.not_nil!)
        return false
      end
    end
  end
  true
end



filename = ARGV.at(0) {
  `import -window root screenshot.png`
  "screenshot.png"
}

img = StumpyPNG.read(filename)



commands = [] of String

solution = solve(img)
if !solution
  STDERR.puts "Unsolvable"
  exit 1
end


solution.each do |step|
  w = "sleep 0.05"
  if step
    if step[0].is_a? Tuple
      x, y = step[0].as(Tuple)
      commands << "mousemove #{x+5} #{y+5}" << w << "mousedown 1" << w
      x, y = step[1].as(Tuple)
      commands << "mousemove #{x+5} #{y+5}" << w << "mouseup 1"
      commands << "sleep 0.2"
    else
      x = step[0].as(Int32)
      y = step[1].as(Int32)
      commands << "mousemove #{x+2} #{y+2}" << w << "mousedown 1" << w << "mouseup 1"
      commands << "sleep 0.5"
    end
  else
    commands << "sleep 0.25"
  end
end


#puts commands.join("\n")
if ARGV.empty?
  Process.run("xdotool", ["-"], input: MemoryIO.new(commands.join("\n")))
end
