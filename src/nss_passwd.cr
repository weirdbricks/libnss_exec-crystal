# Password database NSS functions.
#
# Implements the _nss_exec_setpwent, _nss_exec_endpwent, _nss_exec_getpwent_r,
# _nss_exec_getpwuid_r, and _nss_exec_getpwnam_r entry points that glibc calls
# when "exec" appears in /etc/nsswitch.conf for the passwd database.
#
# Thread safety: @@ent_index is protected by @@mutex. glibc serializes
# set/get/end calls through its own wrappers, but programs that call the _r
# functions directly may not — the mutex covers that case.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"

module NssExec
  module Passwd
    @@ent_index : Int64 = 0
    @@mutex : Mutex = Mutex.new(:reentrant)

    def self.setpwent(stayopen : Int32) : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("setpwent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.endpwent : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("endpwent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.getpwent(result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      @@mutex.synchronize do
        status, output = NssExec.exec_script_long("getpwent", @@ent_index)
        return status unless status == NssStatus::SUCCESS
        return NssStatus::NOTFOUND unless output

        entry = PasswdEntry.parse(output)
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

    def self.getpwuid(uid : UInt32, result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script_long("getpwuid", uid.to_i64)
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output

      entry = PasswdEntry.parse(output)
      unless entry
        errnop.value = LibC::ENOENT
        return NssStatus::UNAVAIL
      end

      pack = entry.fill_c_struct(result, buffer, buflen)
      nss_status, errno = NssExec.pack_result_to_status(pack)
      errnop.value = errno
      nss_status
    end

    def self.getpwnam(name : String, result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getpwnam", name)
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output

      entry = PasswdEntry.parse(output)
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

# ---------------------------------------------------------------------------
# C-exported entry points — names MUST match _nss_<service>_<function>.
# ---------------------------------------------------------------------------

fun _nss_exec_setpwent(stayopen : LibC::Int) : LibC::Int
  NssExec::Passwd.setpwent(stayopen).value
rescue
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_endpwent : LibC::Int
  NssExec::Passwd.endpwent.value
rescue
  NssExec::NssStatus::SUCCESS.value
end

fun _nss_exec_getpwent_r(result : LibC::Passwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Passwd.getpwent(result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_getpwuid_r(uid : LibC::UidT, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  NssExec::Passwd.getpwuid(uid, result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_getpwnam_r(name : UInt8*, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  name_str = String.new(name)
  NssExec::Passwd.getpwnam(name_str, result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end
