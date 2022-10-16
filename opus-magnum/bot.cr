require "crystal-fann"
require "stumpy_core"
require "stumpy_png"
require "x_do"


enum Marble
  None = -1
  Salt = 0
  Air; Fire; Water; Earth
  Vitae; Mors; Quintessence; Quicksilver
  Lead; Tin; Iron; Copper; Silver; Gold

  def symbol
    case self
    when None
      "-"
    when Quicksilver..Gold
      to_s[0..0].upcase
    else
      to_s[0..0].downcase
    end
  end
end

MARBLE_BY_SYMBOL = Marble.values.map { |v| { v.symbol, v } } .to_h

FIELD_X = 1052
FIELD_DX = 66
FIELD_Y = 221
FIELD_DY = 57
FIELD_SIZE = 6

SCAN_RADIUS = 17
PIXELS_TO_SCAN = begin
  pxs = [] of {Int32, Int32}
  (-SCAN_RADIUS + 1 .. SCAN_RADIUS - 1).each do |dy|
    (-SCAN_RADIUS + 1 .. SCAN_RADIUS - 1).each do |dx|
      next if (dx.abs + dy.abs) * 2 > SCAN_RADIUS * 3
      next if dy * 2 < -SCAN_RADIUS && dx * 5 < SCAN_RADIUS
      pxs << {dx, dy}
    end
  end
  pxs
end

def lightness_at(img : StumpyCore::Canvas, x : Int32, y : Int32) : Float64
  r, g, b = img[x, y].to_relative
  max, min = {r, g, b}.max, {r, g, b}.min
  (max + min) / 2
end

def edges_at(img : StumpyCore::Canvas, x : Int32, y : Int32) : Array({Int32, Int32})
  pxs = PIXELS_TO_SCAN.sort_by { |(dx, dy)|
    a = lightness_at(img, x + dx, y + dy)
    neigh = [{-1, 0}, {0, -1}, {1, 0}, {0, 1}].map { |ddx, ddy|
      lightness_at(img, x + dx + ddx, y + dy + ddy)
    }
    -(neigh.max - neigh.min)
  }
  pxs.first(pxs.size // 4)
end

FIELD_POSITIONS = begin
  d = FIELD_SIZE-1
  result = [] of {Int32, Int32}
  (-d .. d).each do |y|
    (-d .. d).each do |x|
      result << {x + d, y + d} unless (y - x).abs > d
    end
  end
  result
end

def img_pos(x : Int32, y : Int32) : {Int32, Int32}
  {FIELD_X + FIELD_DX * (x * 2 - y) // 2, FIELD_Y + FIELD_DY * y}
end

TRAIN_CASES = Marble.values.map { |m|
  {m, [] of Set({Int32, Int32})}
}.to_h

(1..6).each do |i|
  img = StumpyPNG.read("samples/#{i}.png")
  samples = File.read("samples/#{i}.txt").split
  FIELD_POSITIONS.zip(samples) do |pos, symbol|
    marble = MARBLE_BY_SYMBOL[symbol]
    edge_pixels = edges_at(img, *img_pos(*pos)).to_set
    TRAIN_CASES[marble] << edge_pixels
  end
end

ANN = if File.file?("network.fann")
  STDERR.puts "Loading network from file..."
  Fann::Network::Standard.new("network.fann")
else
  STDERR.puts "Teaching network..."
  ann = Fann::Network::Standard.new(PIXELS_TO_SCAN.size, [PIXELS_TO_SCAN.size//2,
                                                          PIXELS_TO_SCAN.size//4], Marble.values.size)
  rng = Random.new(0)

  (FIELD_POSITIONS.size*15).times do
    marble = Marble.values.sample(random: rng)
    edge_pixels = TRAIN_CASES[marble].sample(random: rng)
    ann.train_single(
      PIXELS_TO_SCAN.map { |px| edge_pixels.includes?(px) ? 1.0 : 0.0 },
      Marble.values.map { |v| v == marble ? 1.0 : 0.0 }
    )
  end
  ann.save("network.fann")
  ann
end

struct State
  getter state : Hash({Int32, Int32}, Marble)
  forward_missing_to state

  def_equals_and_hash state
  def_clone

  def initialize(@state = {} of {Int32, Int32} => Marble)
  end

  def score
    state.size
  end

  def clone
    cl = clone
    {cl, with cl yield}
  end

  def to_s(io)
    py = nil
    FIELD_POSITIONS.each do |(x, y)|
      if y != py
        io << "\n" if y > 0
        io << " " * (y - FIELD_SIZE + 1).abs
      end
      io << (self[{x, y}]? || Marble::None).symbol << " "
      py = y
    end
  end
end


def init(img)
  state = State.new

  FIELD_POSITIONS.each do |pos|
    try_edges = edges_at(img, *img_pos(*pos))
    result = ANN.run(PIXELS_TO_SCAN.map { |px| try_edges.includes?(px) ? 1.0 : 0.0 })
    marble = result.zip(Marble.values).sort[-1][1]
    state[pos] = marble unless marble == Marble::None
  end

  state
end

alias Step = Set({Int32, Int32})
alias Solution = Array(Step)

def solve(initial_state : State)
  todo = [initial_state]
  solutions = {initial_state => Solution.new}

  until todo.empty?
    cur_state = todo.min_by &.score

    if rand(100) == 0
      STDERR << todo.size << "      \r"
      STDERR.flush
    end
    todo.delete cur_state
    step(cur_state) do |step|
      state = cur_state.clone
      step.each do |pos|
        state.delete pos
      end
      next if solutions.has_key? state
      todo << state
      solution = solutions[cur_state].dup
      solution << step
      solutions[state] = solution
      if state.empty?
        return solution
      end
    end
  end
  nil
end

def frees(state : State) : Array({Int32, Int32})
  result = Array({Int32, Int32}).new
  state.each_key do |(x, y)|
    if free?(x, y, state)
      result << {x, y}
    end
  end
  result
end

def free?(x : Int32, y : Int32, state : State) : Bool
  neighbors(x, y, state).cycle(2).each_cons(3, reuse: true) do |ms|
    return true if ms.none?
  end
  false
end

def neighbors(x : Int32, y : Int32, state : State? = nil)
  result = Array(Marble?).new
  [{0, -1}, {1, 0}, {1, 1}, {0, 1}, {-1, 0}, {-1, -1}].each do |dx, dy|
    n = {x + dx, y + dy}
    result << state.try(&.[n]?)
  end
  result
end

def step(state : State)
  frees = frees(state).shuffle
  buckets = frees.group_by { |a| state[a] }
  frees.each do |a|
    frees.each do |b|
      next if a == b
      ma, mb = state[a], state[b]
      case ma
      when Marble::Vitae, Marble::Mors
        case mb
        when Marble::Vitae, Marble::Mors
          yield Set{a, b} unless ma == mb
        end
      when Marble::Lead..Marble::Gold
        break if state.each_value.any? { |m| (Marble::Lead...ma) === m }
        if ma == Marble::Gold
          yield Set{a}
          break
        elsif mb == Marble::Quicksilver
          yield Set{a, b}
        end
      when Marble::Salt..Marble::Earth
        case mb
        when ma, Marble::Salt
          yield Set{a, b}
        end
      when Marble::Quintessence
        Indexable.each_cartesian(
          [
            [a], buckets[Marble::Air], buckets[Marble::Fire],
            buckets[Marble::Water], buckets[Marble::Earth]
          ], reuse: true
        ) do |product|
          yield product.to_set
        end rescue nil
        break
      else
        break
      end
    end
  end
end


filename = ARGV.fetch(0) {
  `import -window root screenshot.png`
  "screenshot.png"
}

img = StumpyPNG.read(filename)


commands = [] of String

state = init(img)
STDERR.puts state
solution = solve(state)
if !solution
  abort "Unsolvable"
end

if ARGV.empty?
  window = XDo.new.active_window
  solution.each do |step|
    step.each do |coord|
      x, y = img_pos(*coord)
      window.move_mouse(x, y)
      sleep 0.05
      window.mouse_down(:left)
      sleep 0.05
      window.mouse_up(:left)
      sleep 0.05
    end
  end
end
