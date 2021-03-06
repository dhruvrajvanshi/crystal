STDIN = FileDescriptorIO.new(0, blocking: LibC.isatty(0) == 0, edge_triggerable: ifdef darwin; false; else; true; end)
STDOUT = (FileDescriptorIO.new(1, blocking: LibC.isatty(1) == 0, edge_triggerable: ifdef darwin; false; else; true; end)).tap { |f| f.flush_on_newline = true }
STDERR = FileDescriptorIO.new(2, blocking: LibC.isatty(2) == 0, edge_triggerable: ifdef darwin; false; else; true; end)

PROGRAM_NAME = String.new(ARGV_UNSAFE.value)
ARGV = (ARGV_UNSAFE + 1).to_slice(ARGC_UNSAFE - 1).map { |c_str| String.new(c_str) }
ARGF = IO::ARGF.new(ARGV, STDIN)

# Repeatedly executes the block.
#
# ```
# loop do
#   print "Input: "
#   line = gets
#   break unless line
#   # ...
# end
# ```
def loop
  while true
    yield
  end
end

def gets(*args)
  STDIN.gets(*args)
end

def read_line(*args)
  STDIN.read_line(*args)
end

def print(*objects : _)
  STDOUT.print *objects
end

def print!(*objects : _)
  print *objects
  STDOUT.flush
  nil
end

def printf(format_string, *args)
  printf format_string, args
end

def printf(format_string, args : Array | Tuple)
  STDOUT.printf format_string, args
end

def sprintf(format_string, *args)
  sprintf format_string, args
end

def sprintf(format_string, args : Array | Tuple)
  String.build(format_string.bytesize) do |str|
    String::Formatter.new(format_string, args, str).format
  end
end

def puts(*objects)
  STDOUT.puts *objects
end

def p(obj)
  obj.inspect(STDOUT)
  puts
  obj
end

# :nodoc:
module AtExitHandlers
  @@handlers = nil

  def self.add(handler)
    handlers = @@handlers ||= [] of ->
    handlers << handler
  end

  def self.run
    return if @@running
    @@running = true

    begin
      @@handlers.try &.reverse_each &.call
    rescue handler_ex
      puts "Error running at_exit handler: #{handler_ex}"
    end
  end
end

# Registers the given `Proc` for execution when the program exits.
# If multiple handlers are registered, they are executed in reverse order of registration.
#
# ```
# def do_at_exit(str1)
#   at_exit { print str1 }
# end
#
# at_exit { puts "cruel world" }
# do_at_exit("goodbye ")
# exit
# ```
#
# Produces:
#
# ```text
# goodbye cruel world
# ```
def at_exit(&handler)
  AtExitHandlers.add(handler)
end

# Terminates execution immediately, returning the given status code
# to the invoking environment.
#
# Registered `at_exit` procs are executed.
def exit(status = 0)
  AtExitHandlers.run
  STDOUT.flush
  STDERR.flush
  Process.exit(status)
end

# Terminates execution immediately, printing *message* to STDERR and
# then calling `exit(status)`.
def abort(message, status = 1)
  STDERR.puts message if message
  exit status
end

Signal::PIPE.ignore

# Background loop to cleanup unused fiber stacks
spawn do
  loop do
    sleep 5
    Fiber.stack_pool_collect
  end
end
