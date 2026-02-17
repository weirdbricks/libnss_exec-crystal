# Password database NSS functions
# Copyright (c) 2025 [Your Name]
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"
require "./nss_types"

module NssExec
  module Passwd
    # Enumeration index for getpwent
    # Note: We removed mutex synchronization as NSS handles thread safety
    @@ent_index = 0
    
    # Reset the passwd enumeration index
    # Called by setpwent(3)
    def self.setpwent(stayopen : Int32) : NssStatus
      status, _ = NssExec.exec_script("setpwent")
      @@ent_index = 0 if status == NssStatus::SUCCESS
      status
    end
    
    # Close passwd enumeration
    # Called by endpwent(3)
    def self.endpwent : NssStatus
      status, _ = NssExec.exec_script("endpwent")
      status
    end
    
    # Get next passwd entry during enumeration
    # Called by getpwent_r(3)
    def self.getpwent(result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      # Call script with current index
      status, output = NssExec.exec_script_long("getpwent", @@ent_index.to_i64)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      # Parse the output
      entry = PasswdEntry.parse(output)
      unless entry
        errnop.value = LibC::ERANGE
        return NssStatus::UNAVAIL
      end
      
      # Fill the C structure
      pack_result = entry.fill_c_struct(result, buffer, buffer_length)
      nss_status, errno = NssExec.handle_pack_result(pack_result)
      errnop.value = errno
      
      # Only increment index on success
      @@ent_index += 1 if nss_status == NssStatus::SUCCESS
      
      nss_status
    end
    
    # Get passwd entry by user ID
    # Called by getpwuid_r(3)
    def self.getpwuid(uid : UInt32, result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getpwuid", uid.to_i64)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      entry = PasswdEntry.parse(output)
      unless entry
        errnop.value = LibC::ERANGE
        return NssStatus::UNAVAIL
      end
      
      pack_result = entry.fill_c_struct(result, buffer, buffer_length)
      nss_status, errno = NssExec.handle_pack_result(pack_result)
      errnop.value = errno
      nss_status
    end
    
    # Get passwd entry by username
    # Called by getpwnam_r(3)
    def self.getpwnam(name : String, result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getpwnam", name)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      entry = PasswdEntry.parse(output)
      unless entry
        errnop.value = LibC::ERANGE
        return NssStatus::UNAVAIL
      end
      
      pack_result = entry.fill_c_struct(result, buffer, buffer_length)
      nss_status, errno = NssExec.handle_pack_result(pack_result)
      errnop.value = errno
      nss_status
    end
  end
end

# C-compatible exported functions
# These are the actual NSS entry points that glibc will call
# Function names MUST match the pattern: _nss_<service>_<function>
# where <service> is "exec" (from the library name libnss_exec.so)

fun _nss_exec_setpwent(stayopen : LibC::Int) : LibC::Int
  NssExec::Passwd.setpwent(stayopen).value
end

fun _nss_exec_endpwent : LibC::Int
  NssExec::Passwd.endpwent.value
end

fun _nss_exec_getpwent_r(result : LibC::Passwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Passwd.getpwent(result, buffer, buflen.to_i32, errnop).value
end

fun _nss_exec_getpwuid_r(uid : LibC::UidT, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  NssExec::Passwd.getpwuid(uid, result, buffer, buflen.to_i32, errnop).value
end

fun _nss_exec_getpwnam_r(name : UInt8*, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  # Safely convert C string to Crystal string
  name_str = String.new(name)
  NssExec::Passwd.getpwnam(name_str, result, buffer, buflen.to_i32, errnop).value
rescue
  # If string conversion fails, return UNAVAIL
  NssExec::NssStatus::UNAVAIL.value
end
