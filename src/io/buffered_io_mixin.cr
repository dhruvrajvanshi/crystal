module BufferedIOMixin
  include IO

  BUFFER_SIZE = 8192

  # Due to https://github.com/manastech/crystal/issues/456 this
  # initialization logic must be copied in the included type's
  # initialize method:
  #
  # def initialize
  #   @in_buffer_rem = Slice.new(Pointer(UInt8).null, 0)
  #   @out_count = 0
  #   @sync = false
  #   @flush_on_newline = false
  # end

  abstract def unbuffered_read(slice : Slice(UInt8), count)
  abstract def unbuffered_write(slice : Slice(UInt8), count)
  abstract def unbuffered_flush
  abstract def unbuffered_close
  abstract def unbuffered_rewind

  def gets(delimiter : Char, limit : Int)
    if delimiter.ord >= 128
      return super
    end

    raise ArgumentError.new "negative limit" if limit < 0

    limit = Int32::MAX if limit < 0

    delimiter_byte = delimiter.ord.to_u8

    # We first check, after filling the buffer, if the delimiter
    # is already in the buffer. In that case it's much faster to create
    # a String from a slice of the buffer instead of appending to a
    # StringIO, which happens in the other case.
    fill_buffer if @in_buffer_rem.empty?
    if @in_buffer_rem.empty?
      return nil
    end

    index = @in_buffer_rem.index(delimiter_byte)
    if index
      # If we find it past the limit, limit the result
      if index > limit
        index = limit
      else
        index += 1
      end

      string = String.new(@in_buffer_rem[0, index])
      @in_buffer_rem += index
      return string
    end

    # We didn't find the delimiter, so we append to a StringIO until we find it,
    # or we reach the limit
    String.build do |buffer|
      loop do
        available = Math.min(@in_buffer_rem.length, limit)
        buffer.write @in_buffer_rem, available
        @in_buffer_rem += available
        limit -= available

        if limit == 0
          break
        end

        fill_buffer if @in_buffer_rem.empty?

        if @in_buffer_rem.empty?
          if buffer.bytesize == 0
            return nil
          else
            break
          end
        end

        index = @in_buffer_rem.index(delimiter_byte)
        if index
          if index > limit
            index = limit
          else
            index += 1
          end
          buffer.write @in_buffer_rem, index
          @in_buffer_rem += index
          break
        end
      end
    end
  end

  def read_byte
    fill_buffer if @in_buffer_rem.empty?
    if @in_buffer_rem.empty?
      nil
    else
      b = @in_buffer_rem[0]
      @in_buffer_rem += 1
      b
    end
  end

  def read_char_with_bytesize
    return super unless @in_buffer_rem.length >= 4

    first = @in_buffer_rem[0].to_u32
    if first < 0x80
      @in_buffer_rem += 1
      return first.chr, 1
    end

    second = (@in_buffer_rem[1] & 0x3f).to_u32
    if first < 0xe0
      @in_buffer_rem += 2
      return ((first & 0x1f) << 6 | second).chr, 2
    end

    third = (@in_buffer_rem[2] & 0x3f).to_u32
    if first < 0xf0
      @in_buffer_rem += 3
      return ((first & 0x0f) << 12 | (second << 6) | third).chr, 3
    end

    fourth = (@in_buffer_rem[3] & 0x3f).to_u32
    if first < 0xf8
      @in_buffer_rem += 4
      return ((first & 0x07) << 18 | (second << 12) | (third << 6) | fourth).chr, 4
    end

    raise InvalidByteSequenceError.new
  end

  def read(slice : Slice(UInt8), count)
    total_read = 0

    while count > 0
      if @in_buffer_rem.empty?
        # If we are asked to read more than the buffer's size,
        # read directly into the slice.
        if count >= BUFFER_SIZE
          to_read = unbuffered_read(slice, count).to_i
          total_read += to_read
          break
        else
          fill_buffer
          break if @in_buffer_rem.empty?
        end
      end

      to_read = Math.min(count, @in_buffer_rem.length)
      slice.copy_from(@in_buffer_rem.pointer(to_read), to_read)
      @in_buffer_rem += to_read
      count -= to_read
      slice += to_read
      total_read += to_read
    end

    total_read
  end

  def read(length : Int)
    raise ArgumentError.new "negative length" if length < 0

    fill_buffer if @in_buffer_rem.empty?

    # If we have enough content in the buffer, use it
    if length <= @in_buffer_rem.length
      string = String.new(@in_buffer_rem[0, length])
      @in_buffer_rem += length
      return string
    end

    super
  end

  def write(slice : Slice(UInt8), count)
    if sync?
      return unbuffered_write(slice, count).to_i
    end

    if flush_on_newline?
      index = slice[0, count.to_i32].rindex('\n'.ord.to_u8)
      if index
        flush
        index += 1
        unbuffered_write(slice, index)
        slice += index
        count -= index
      end
    end

    if count >= BUFFER_SIZE
      flush
      unbuffered_write(slice, count)
      return
    end

    if count > BUFFER_SIZE - @out_count
      flush
    end

    slice.copy_to(out_buffer + @out_count, count)
    @out_count += count
  end

  def write_byte(byte : UInt8)
    if sync?
      return super
    end

    if @out_count >= BUFFER_SIZE
      flush
    end
    out_buffer[@out_count] = byte
    @out_count += 1

    if flush_on_newline? && byte === '\n'
      flush
    end
  end

  def flush_on_newline=(flush_on_newline)
    @flush_on_newline = !!flush_on_newline
  end

  def flush_on_newline?
    @flush_on_newline
  end

  def sync=(sync)
    flush if sync && !@sync
    @sync = !!sync
  end

  def sync?
    @sync
  end

  def flush
    unbuffered_write(Slice.new(out_buffer, BUFFER_SIZE), @out_count) if @out_count > 0
    unbuffered_flush
    @out_count = 0
  end

  def close
    flush if @out_count > 0
    unbuffered_close
  end

  def rewind
    unbuffered_rewind
    @in_buffer_rem = Slice.new(Pointer(UInt8).null, 0)
  end

  private def fill_buffer
    in_buffer = in_buffer()
    length = unbuffered_read(Slice.new(in_buffer, BUFFER_SIZE), BUFFER_SIZE).to_i
    @in_buffer_rem = Slice.new(in_buffer, length)
  end

  private def in_buffer
    @in_buffer ||= GC.malloc_atomic(BUFFER_SIZE.to_u32) as UInt8*
  end

  private def out_buffer
    @out_buffer ||= GC.malloc_atomic(BUFFER_SIZE.to_u32) as UInt8*
  end
end
