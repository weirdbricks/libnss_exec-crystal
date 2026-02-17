# Core NSS exec module — script execution and status mapping.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# Original project: https://github.com/tests-always-included/libnss_exec
# License: MIT (see LICENSE file)

require "./nss_types"

# Low-level C I/O — we use popen/pclose directly because this code runs
# inside glibc's NSS machinery where we want minimal Crystal runtime
# involvement.
lib LibC
  fun popen(command : UInt8*, mode : UInt8*) : Void*
  fun pclose(stream : Void*) : Int32
  fun fgets(buffer : UInt8*, size : Int32, stream : Void*) : UInt8*
end

module NssExec
  VERSION = "2.1.0"

  # Path to the external script that services NSS queries.
  # Configurable at compile time with -DNSS_EXEC_SCRIPT=/path/to/script.
  NSS_EXEC_SCRIPT = "/sbin/nss_exec"

  # Maximum size of a single line read from the script's stdout.
  EXEC_BUFFER_SIZE = 4096

  # Escape a string for safe inclusion in a POSIX shell command.
  # Wraps in single quotes and escapes any embedded single quotes.
  # This prevents shell injection when user-supplied data (usernames,
  # etc.) is passed as an argument to the script.
  private def self.shell_escape(str : String) : String
    "'" + str.gsub("'", "'\\''") + "'"
  end

  # Execute the NSS script with the given command code and optional argument.
  #
  # Returns a tuple of {NssStatus, output_line_or_nil}.
  #
  # The script's exit code is mapped to an NssStatus:
  #   0 → SUCCESS
  #   1 → NOTFOUND
  #   2 → TRYAGAIN
  #   * → UNAVAIL
  def self.exec_script(command : String, argument : String? = nil) : {NssStatus, String?}
    cmd = if argument
            "#{NSS_EXEC_SCRIPT} #{command} #{shell_escape(argument)}"
          else
            "#{NSS_EXEC_SCRIPT} #{command}"
          end

    fp = LibC.popen(cmd.to_unsafe, "r".to_unsafe)
    return {NssStatus::UNAVAIL, nil} if fp.null?

    # Read one line — NSS entries are always single-line.
    buf = Pointer(UInt8).malloc(EXEC_BUFFER_SIZE)
    got_output = !LibC.fgets(buf, EXEC_BUFFER_SIZE, fp).null?

    # pclose returns the wait-status; extract the real exit code.
    wait_status = LibC.pclose(fp)
    exit_code = (wait_status >> 8) & 0xFF

    status = case exit_code
             when 0 then NssStatus::SUCCESS
             when 1 then NssStatus::NOTFOUND
             when 2 then NssStatus::TRYAGAIN
             else        NssStatus::UNAVAIL
             end

    if status == NssStatus::SUCCESS && got_output
      line = String.new(buf).strip
      line.empty? ? {status, nil} : {status, line}
    else
      {status, nil}
    end
  rescue ex
    # Any Crystal-level exception (bad UTF-8, OOM, etc.) → UNAVAIL.
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
