# Group database NSS functions.
#
# Implements _nss_exec_setgrent, _nss_exec_endgrent, _nss_exec_getgrent_r,
# _nss_exec_getgrgid_r, and _nss_exec_getgrnam_r.
#
# Thread safety: @@ent_index is protected by @@mutex.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"

module NssExec
  module Group
    @@ent_index : Int64 = 0
    @@mutex : Mutex = Mutex.new(:reentrant)

    def self.setgrent(stayopen : Int32) : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("setgrent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.endgrent : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("endgrent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.getgrent(result : LibC::Group*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      @@mutex.synchronize do
        status, output = NssExec.exec_script_long("getgrent", @@ent_index)
        return status unless status == NssStatus::SUCCESS
        return NssStatus::NOTFOUND unless output

        entry = GroupEntry.parse(output)
        unless entry
          errnop.value = LibC::ENOENT
          return NssStatus::UNAVAIL
        end

        pack = entry.fill_c_struct(result, buffer, buflen)
        nss_status, errno = NssExec.pack_result_to_status(pack)
        errnop.value = errno
        @@ent_index += 1 if nss_status == NssStatus::SUCCESS
        nss_status
      end
    end

    def self.getgrgid(gid : UInt32, result : LibC::Group*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getgrgid", gid.to_i64)
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output

      entry = GroupEntry.parse(output)
      unless entry
        errnop.value = LibC::ENOENT
        return NssStatus::UNAVAIL
      end

      pack = entry.fill_c_struct(result, buffer, buflen)
      nss_status, errno = NssExec.pack_result_to_status(pack)
      errnop.value = errno
      nss_status
    end

    def self.getgrnam(name : String, result : LibC::Group*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getgrnam", name)
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output

      entry = GroupEntry.parse(output)
      unless entry
        errnop.value = LibC::ENOENT
        return NssStatus::UNAVAIL
      end

      pack = entry.fill_c_struct(result, buffer, buflen)
      nss_status, errno = NssExec.pack_result_to_status(pack)
      errnop.value = errno
      nss_status
    end
  end
end

# C-exported entry points

fun _nss_exec_setgrent(stayopen : LibC::Int) : LibC::Int
  NssExec::Group.setgrent(stayopen).value
rescue
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_endgrent : LibC::Int
  NssExec::Group.endgrent.value
rescue
  NssExec::NssStatus::SUCCESS.value
end

fun _nss_exec_getgrent_r(result : LibC::Group*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Group.getgrent(result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_getgrgid_r(gid : LibC::GidT, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  NssExec::Group.getgrgid(gid, result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_getgrnam_r(name : UInt8*, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  name_str = String.new(name)
  NssExec::Group.getgrnam(name_str, result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end
