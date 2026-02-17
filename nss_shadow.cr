# Shadow password database NSS functions
# Copyright (c) 2025 [Your Name]
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"
require "./nss_types"

module NssExec
  module Shadow
    # Enumeration index for getspent
    # Note: We removed mutex synchronization as NSS handles thread safety
    @@ent_index = 0
    
    # Reset the shadow enumeration index
    # Called by setspent(3)
    def self.setspent(stayopen : Int32) : NssStatus
      status, _ = NssExec.exec_script("setspent")
      @@ent_index = 0 if status == NssStatus::SUCCESS
      status
    end
    
    # Close shadow enumeration
    # Called by endspent(3)
    def self.endspent : NssStatus
      status, _ = NssExec.exec_script("endspent")
      status
    end
    
    # Get next shadow entry during enumeration
    # Called by getspent_r(3)
    def self.getspent(result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getspent", @@ent_index.to_i64)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      # Parse the output
      entry = ShadowEntry.parse(output)
      unless entry
        errnop.value = LibC::ERANGE
        return NssStatus::UNAVAIL
      end
      
      # Fill the C structure
      pack_result = entry.fill_c_struct(result, buffer, buffer_length)
      nss_status, errno = NssExec.handle_pack_result(pack_result)
      errnop.value = errno
      
      @@ent_index += 1 if nss_status == NssStatus::SUCCESS
      nss_status
    end
    
    # Get shadow entry by username
    # Called by getspnam_r(3)
    def self.getspnam(name : String, result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getspnam", name)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      entry = ShadowEntry.parse(output)
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

fun _nss_exec_setspent(stayopen : LibC::Int) : LibC::Int
  NssExec::Shadow.setspent(stayopen).value
end

fun _nss_exec_endspent : LibC::Int
  NssExec::Shadow.endspent.value
end

fun _nss_exec_getspent_r(result : LibC::Spwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Shadow.getspent(result, buffer, buflen.to_i32, errnop).value
end

fun _nss_exec_getspnam_r(name : UInt8*, result : LibC::Spwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  # Safely convert C string to Crystal string
  name_str = String.new(name)
  NssExec::Shadow.getspnam(name_str, result, buffer, buflen.to_i32, errnop).value
rescue
  # If string conversion fails, return UNAVAIL
  NssExec::NssStatus::UNAVAIL.value
end
