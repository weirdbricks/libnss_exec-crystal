# Crystal implementation of libnss_exec
# Main module providing NSS functionality through external script execution
#
# Copyright (c) 2025 [Your Name]
# Based on the original C implementation by Tyler Akins
# Original project: https://github.com/tests-always-included/libnss_exec
# License: MIT (see LICENSE file)

require "./nss_types"

# Low-level C library bindings we need
lib LibC
  fun popen(command : UInt8*, mode : UInt8*) : Void*
  fun pclose(stream : Void*) : Int32
  fun fgets(buffer : UInt8*, size : Int32, stream : Void*) : UInt8*
  fun snprintf(str : UInt8*, size : SizeT, format : UInt8*, ...) : Int32
end

module NssExec
  VERSION = "2.0.0-crystal"
  
  # Path to the external script that handles NSS queries
  NSS_EXEC_SCRIPT = "/sbin/nss_exec"
  
  # Simple shell escaping - wraps in single quotes and escapes embedded quotes
  private def self.simple_shell_escape(str : String) : String
    "'" + str.gsub("'", "'\\''") + "'"
  end
  
  # Execute external script using pure LibC calls (no Crystal runtime needed)
  def self.exec_script(command_code : String, data : String? = nil) : {NssStatus, String?}
    # Build command string
    command_str = if data
                    escaped = simple_shell_escape(data)
                    "#{NSS_EXEC_SCRIPT} #{command_code} #{escaped}"
                  else
                    "#{NSS_EXEC_SCRIPT} #{command_code}"
                  end
    
    # Use popen to execute command
    fp = LibC.popen(command_str.to_unsafe, "r".to_unsafe)
    return {NssStatus::UNAVAIL, nil} if fp.null?
    
    # Read output (single line is sufficient for NSS)
    buffer = Pointer(UInt8).malloc(4096)
    result_ptr = LibC.fgets(buffer, 4096, fp)
    
    # Close pipe and get exit status
    exit_status = LibC.pclose(fp)
    exit_code = exit_status >> 8  # Extract actual exit code from wait status
    
    # Map exit code to NSS status
    nss_status = case exit_code
                 when 0 then NssStatus::SUCCESS
                 when 1 then NssStatus::NOTFOUND
                 when 2 then NssStatus::TRYAGAIN
                 else        NssStatus::UNAVAIL
                 end
    
    # Return result
    if nss_status == NssStatus::SUCCESS && !result_ptr.null?
      output = String.new(buffer).strip
      output.empty? ? {nss_status, nil} : {nss_status, output}
    else
      {nss_status, nil}
    end
  rescue
    {NssStatus::UNAVAIL, nil}
  end
  
  # Execute script with a numeric parameter (UID, GID, index, etc)
  def self.exec_script_long(command_code : String, value : Int64) : {NssStatus, String?}
    exec_script(command_code, value.to_s)
  end
  
  # Handle the result of filling a C struct
  # Returns appropriate NSS status and errno value
  def self.handle_pack_result(pack_result : Int32) : {NssStatus, Int32}
    case pack_result
    when -1
      # Script execution failed or returned wrong format
      {NssStatus::UNAVAIL, LibC::ENOENT}
    when 0
      # Success
      {NssStatus::SUCCESS, 0}
    else
      # Buffer too small (pack_result == 1 means ERANGE)
      {NssStatus::TRYAGAIN, LibC::ERANGE}
    end
  end
end
