require "stumpy_png"
require "nonograms/nonogram"


struct Rect(T)
  def initialize(@left : T, @top : T, @right : T, @bottom : T)
  end

  getter left, top, right, bottom

  def width
    right - left
  end
  def height
    bottom - top
  end

  def p1
    {left, top}
  end
  def p2
    {right, bottom}
  end
  def center
    {(left + right) / 2, (top + bottom) / 2}
  end

  def inspect(io)
    io << "(" << left << "," << top << ")->(" << right << "," << bottom << ")"
  end
end

private def fill(x, y)
  todo = [{x, y}]
  done = Set({Int32, Int32}).new
  until todo.empty?
    x, y = todo.pop
    if yield x, y
      done.add({x, y})
      { {-1, 0}, {0, -1}, {1, 0}, {0, 1} }.each do |(dx, dy)|
        p = {x + dx, y + dy}
        todo.push p unless done.includes? p
      end
    end
  end
  done
end

private def img_fill(img, x, y)
  fill(x, y) do |x, y|
    if 0 <= x < img.width && 0 <= y < img.height
      yield x, y
    end
  end
end

def flood_fill(img, x, y, threshold = 0)
  origin = img[x, y].to_rgb8
  img_fill(img, x, y) do |x, y|
    origin.zip(img[x, y].to_rgb8).all? { |a, b|
      (a - b).abs <= threshold
    }
  end
end

private def split_coords(points)
  {points.map(&.first).to_set, points.map(&.last).to_set}
end

def bounds(points)
  xs, ys = split_coords(points)
  Rect.new(xs.min, ys.min, xs.max + 1, ys.max + 1)
end

def find_regions(img)
  x, y = {0, img.height / 2}
  until img[x, y].to_rgb8 == {0, 0, 0}
    x += 1
  end
  outer_frame = bounds(flood_fill(img, x, y))
  x, y = outer_frame.p1
  while img[x, y].to_rgb8 == {0, 0, 0}
    x += 1
    y += 1
  end
  inner_frame = bounds(flood_fill(img, x + 1, y + 1))
  x, y = inner_frame.p1
  until img[x, y].to_rgb8 == {255, 255, 255}
    x += 1
    y += 1
  end
  preview_area = bounds(flood_fill(img, x + 1, y + 1))
  {
    Rect.new(preview_area.left, preview_area.bottom, preview_area.right, inner_frame.bottom), # rows
    Rect.new(preview_area.right, preview_area.top, inner_frame.right, preview_area.bottom), # cols
    Rect.new(*preview_area.p2, *inner_frame.p2) # play
  }
end

def field_size(img, area)
  width = 0
  y = area.top + 15
  x = area.left + 2
  while x < area.right - 2
    if img[x, y] != img[x+1, y]
      width += 1
      x += 1
    end
    x += 1
  end

  height = 0
  x = area.left + 15
  y = area.top + 2
  while y < area.bottom - 2
    if img[x, y] != img[x, y+1]
      height += 1
      y += 1
    end
    y += 1
  end

  {width / 2, height / 2}
end

def pos_to_pix(i, size, pixel_size)
  ((i + 0.5) / size * pixel_size).round.to_i
end
def pix_to_pos(x, size, pixel_size)
  (x.to_f / pixel_size * size - 0.5).round.to_i
end

def find_digits(img, area, size)
  width, height = size
  (0...height).each do |y|
    py_base = area.top + pos_to_pix(y, height, area.height)
    px = area.left
    while px < area.right
      (py_base-3 .. py_base+2).each do |py|
        if img[px, py].to_rgb8 == {247, 247, 247}
          number_pixels = flood_fill(img, px, py, threshold: 64)
          number_bounds = bounds(number_pixels)
          (number_bounds.top...number_bounds.bottom).each do |ny|
            (number_bounds.left...number_bounds.right).each do |nx|
              unless number_pixels.includes?({nx, ny})
                img[nx, ny] = StumpyCore::RGBA.from_rgb8(0, 0, 0)
              end
            end
          end
          yield number_bounds, {pix_to_pos(number_bounds.center.first - area.left, width, area.width), y}
          px = number_bounds.right - 1
          break
        end
      end
      px += 1
    end
  end
end

private def gray(color : StumpyCore::RGBA)
  (color.r.to_i + color.g.to_i + color.b.to_i) / (3 * 256)
end

private def lerp(start, finish, num, denom = 1)
  start + (finish - start) * num / denom
end

private def compare_symbols(img1, area1, img2, area2)
  score = 0
  (res_y = {area1.height, area2.height}.max).times do |y|
    (res_x = {area1.width, area2.width}.max).times do |x|
      cols = { {img1, area1}, {img2, area2} }.map { |(img, area)|
        gray(img[lerp(area.left, area.right, x, res_x), lerp(area.top, area.bottom, y, res_y)])
      }
      score += (cols.first - cols.last).abs
    end
  end
  score
end

DIGITS_IMG = StumpyPNG.read("digits.png")
DIGITS_AREAS = [] of Rect(Int32)
find_digits(DIGITS_IMG, Rect.new(0, 0, DIGITS_IMG.width, DIGITS_IMG.height), {10, 1}) do |area|
  DIGITS_AREAS << area
end

def recognize_digit(img, area)
  (0..9).min_by { |n|
    compare_symbols(img, area, DIGITS_IMG, DIGITS_AREAS[n])
  }
end

def recognize_field(img)
  rows_area, cols_area, play_area = find_regions(img)
  field_width, field_height = field_size(img, play_area)

  rows_width = (rows_area.width.to_f / play_area.width * field_width).round.to_i
  rows = Array.new(field_height) { Array.new(rows_width) { "" } }
  find_digits(img, rows_area, {rows_width, field_height}) do |area, pos|
    rows[pos.last][pos.first] += recognize_digit(img, area).to_s
  end
  rows = rows.map(&.reject(&.empty?).map(&.to_i))

  cols_height = (cols_area.height.to_f / play_area.height * field_height).round.to_i
  cols = Array.new(field_width) { Array.new(cols_height) { "" } }
  find_digits(img, cols_area, {field_width, cols_height}) do |area, pos|
    cols[pos.first][pos.last] += recognize_digit(img, area).to_s
  end
  cols = cols.map(&.reject(&.empty?).map(&.to_i))

  {Nonogram.new(rows, cols), play_area}
end

class SolutionClicker
  def initialize(@field : Nonogram, @play_area : Rect(Int32))
    @xdotool = Process.new("xdotool", ["-"], input: nil)
    @xdotool.input.flush_on_newline = true
    @done = Set({Int32, Int32}).new
  end

  private def send(*cmd)
    s = (cmd.join(' ') + '\n')
    @xdotool.input.write(s.to_slice)
  end

  {% for line in [:row.id, :col.id] %}
    def click_{{line}}({{line}}_i)
      wait = "sleep 0.04"
      prev = false
      line = @field.{{line}}s[{{line}}_i]
      line.each_with_index do |cell, {{line == :row ? :col_i.id : :row_i.id}}|
        if cell.full?
          if !@done.includes?({row_i, col_i})
            send(
              "mousemove",
              lerp(@play_area.left, @play_area.right, col_i*2 + 1, @field.width*2),
              lerp(@play_area.top, @play_area.bottom, row_i*2 + 1, @field.height*2),
              wait
            )
            send "mousedown 1", wait unless prev
            @done << {row_i, col_i}
            prev = true
          end
        elsif prev
          prev = false
          send "mouseup 1", wait
        end
      end
      send "mouseup 1", wait if prev
    end
  {% end %}

  def click(row_i = -1, col_i = -1)
    if row_i >= 0
      click_row(row_i)
    elsif col_i >= 0
      click_col(col_i)
    else
      @field.height.times do |row_i|
        click_row(row_i)
      end
    end
  end

  def finish
    @xdotool.input.close
    @xdotool.wait
  end
end


filename = ARGV.at(0) {
  `import -window root screenshot.png`
  "screenshot.png"
}

field, play_area = recognize_field(StumpyPNG.read(filename))

if ARGV.empty?
  solution_clicker = SolutionClicker.new(field, play_area)
  begin
    status = field.solve! do |(row, col)|
      puts; puts field
      print "#{100 * field.count &.known? / field.size}%\r"
#       solution_clicker.click(row, col)
    end
    puts status
    solution_clicker.click if status.solved?
  ensure
    solution_clicker.finish
  end
else
  status = field.solve! do
    puts; puts field
    print "#{100 * field.count &.known? / field.size}%\r"
  end
  puts status
end
