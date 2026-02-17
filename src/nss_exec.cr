# Core NSS exec module — script execution and status mapping.
#
# Uses fork/execve directly instead of popen("/bin/sh -c ..."). This:
#   - Eliminates the shell as an attack surface (no injection possible)
#   - Spawns one fewer process per lookup
#   - Passes arguments as argv[] (no escaping needed)
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# Original project: https://github.com/tests-always-included/libnss_exec
# License: MIT (see LICENSE file)

require "./nss_types"

# Most POSIX functions (pipe, fork, dup2, _exit, waitpid, read, close, access)
# are already declared in Crystal's LibC stdlib. We only need execve.
lib LibC
  fun execve(path : UInt8*, argv : UInt8**, envp : UInt8**) : Int32
end

module NssExec
  VERSION = "2.2.0"

  # Path to the external script that services NSS queries.
  NSS_EXEC_SCRIPT = "/sbin/nss_exec"

  # Maximum bytes read from the child's stdout. NSS entries are single-line
  # and well under this limit.
  READ_BUFFER_SIZE = 4096

  # Execute the NSS script via fork/execve with the given command and optional
  # argument. No shell is involved — arguments are passed directly as argv[].
  #
  # Returns {NssStatus, output_line_or_nil}.
  #
  # Exit code mapping:
  #   0 → SUCCESS    1 → NOTFOUND    2 → TRYAGAIN    * → UNAVAIL
  def self.exec_script(command : String, argument : String? = nil) : {NssStatus, String?}
    # Quick check: is the script even there and executable?
    return {NssStatus::UNAVAIL, nil} unless LibC.access(NSS_EXEC_SCRIPT.to_unsafe, LibC::X_OK) == 0

    # Create a pipe: child writes to pipefd[1], parent reads from pipefd[0].
    pipefd = StaticArray(Int32, 2).new(0)
    return {NssStatus::UNAVAIL, nil} if LibC.pipe(pipefd) != 0

    pid = LibC.fork
    if pid < 0
      # Fork failed.
      LibC.close(pipefd[0])
      LibC.close(pipefd[1])
      return {NssStatus::UNAVAIL, nil}
    end

    if pid == 0
      # ── Child process ──────────────────────────────────────────────
      # Redirect stdout to the write end of the pipe.
      LibC.close(pipefd[0])
      LibC.dup2(pipefd[1], 1) # stdout = pipe write end
      LibC.close(pipefd[1])

      # Build argv. We need null-terminated C strings in a null-terminated array.
      if argument
        argv = StaticArray(Pointer(UInt8), 4).new(Pointer(UInt8).null)
        argv[0] = NSS_EXEC_SCRIPT.to_unsafe
        argv[1] = command.to_unsafe
        argv[2] = argument.to_unsafe
        # argv[3] already null
      else
        argv = StaticArray(Pointer(UInt8), 3).new(Pointer(UInt8).null)
        argv[0] = NSS_EXEC_SCRIPT.to_unsafe
        argv[1] = command.to_unsafe
        # argv[2] already null
      end

      # Empty environment — the script inherits nothing.
      # If you need PATH or other vars, build a minimal envp here.
      envp = StaticArray(Pointer(UInt8), 2).new(Pointer(UInt8).null)
      envp[0] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin".to_unsafe
      # envp[1] already null

      LibC.execve(NSS_EXEC_SCRIPT.to_unsafe, argv.to_unsafe, envp.to_unsafe)
      # execve only returns on failure.
      LibC._exit(127)
    end

    # ── Parent process ──────────────────────────────────────────────
    LibC.close(pipefd[1]) # Close write end — only child writes.

    # Read the child's output.
    buf = Pointer(UInt8).malloc(READ_BUFFER_SIZE)
    total_read = 0_i64

    loop do
      remaining = READ_BUFFER_SIZE - total_read - 1 # Reserve 1 byte for NUL
      break if remaining <= 0

      bytes = LibC.read(pipefd[0], (buf + total_read).as(Void*), remaining.to_u64)
      break if bytes <= 0
      total_read += bytes
    end

    LibC.close(pipefd[0])
    buf[total_read] = 0_u8 # NUL-terminate

    # Wait for child to exit.
    wait_status = 0
    LibC.waitpid(pid, pointerof(wait_status), 0)

    # Extract exit code from wait status (WEXITSTATUS macro equivalent).
    exit_code = (wait_status >> 8) & 0xFF

    status = case exit_code
             when 0 then NssStatus::SUCCESS
             when 1 then NssStatus::NOTFOUND
             when 2 then NssStatus::TRYAGAIN
             else        NssStatus::UNAVAIL
             end

    if status == NssStatus::SUCCESS && total_read > 0
      line = String.new(buf, total_read).strip
      line.empty? ? {status, nil} : {status, line}
    else
      {status, nil}
    end
  rescue
    {NssStatus::UNAVAIL, nil}
  end

  # Convenience: call exec_script with a numeric argument.
  def self.exec_script_long(command : String, value : Int64) : {NssStatus, String?}
    exec_script(command, value.to_s)
  end

  # Map a fill_c_struct return code to (NssStatus, errno).
  #   0 → SUCCESS / errno 0
  #   1 → TRYAGAIN / ERANGE  (buffer too small)
  #  -1 → UNAVAIL  / ENOENT  (parse failure)
  def self.pack_result_to_status(pack_result : Int32) : {NssStatus, Int32}
    case pack_result
    when 0 then {NssStatus::SUCCESS, 0}
    when 1 then {NssStatus::TRYAGAIN, LibC::ERANGE}
    else        {NssStatus::UNAVAIL, LibC::ENOENT}
    end
  end
end
