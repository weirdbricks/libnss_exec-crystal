# Group database NSS functions
# Copyright (c) 2025 [Your Name]
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"
require "./nss_types"

module NssExec
  module Group
    # Enumeration index for getgrent
    # Note: We removed mutex synchronization as NSS handles thread safety
    @@ent_index = 0
    
    # Reset the group enumeration index
    # Called by setgrent(3)
    def self.setgrent(stayopen : Int32) : NssStatus
      status, _ = NssExec.exec_script("setgrent")
      @@ent_index = 0 if status == NssStatus::SUCCESS
      status
    end
    
    # Close group enumeration
    # Called by endgrent(3)
    def self.endgrent : NssStatus
      status, _ = NssExec.exec_script("endgrent")
      status
    end
    
    # Get next group entry during enumeration
    # Called by getgrent_r(3)
    def self.getgrent(result : LibC::Group*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getgrent", @@ent_index.to_i64)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      # Parse the output
      entry = GroupEntry.parse(output)
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
    
    # Get group by group ID
    # Called by getgrgid_r(3)
    def self.getgrgid(gid : UInt32, result : LibC::Group*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getgrgid", gid.to_i64)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      entry = GroupEntry.parse(output)
      unless entry
        errnop.value = LibC::ERANGE
        return NssStatus::UNAVAIL
      end
      
      pack_result = entry.fill_c_struct(result, buffer, buffer_length)
      nss_status, errno = NssExec.handle_pack_result(pack_result)
      errnop.value = errno
      nss_status
    end
    
    # Get group by name
    # Called by getgrnam_r(3)
    def self.getgrnam(name : String, result : LibC::Group*, buffer : Pointer(UInt8),
                      buffer_length : Int32, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getgrnam", name)
      
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output
      
      entry = GroupEntry.parse(output)
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

fun _nss_exec_setgrent(stayopen : LibC::Int) : LibC::Int
  NssExec::Group.setgrent(stayopen).value
end

fun _nss_exec_endgrent : LibC::Int
  NssExec::Group.endgrent.value
end

fun _nss_exec_getgrent_r(result : LibC::Group*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Group.getgrent(result, buffer, buflen.to_i32, errnop).value
end

fun _nss_exec_getgrgid_r(gid : LibC::GidT, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  NssExec::Group.getgrgid(gid, result, buffer, buflen.to_i32, errnop).value
end

fun _nss_exec_getgrnam_r(name : UInt8*, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  # Safely convert C string to Crystal string
  name_str = String.new(name)
  NssExec::Group.getgrnam(name_str, result, buffer, buflen.to_i32, errnop).value
rescue
  # If string conversion fails, return UNAVAIL
  NssExec::NssStatus::UNAVAIL.value
end
