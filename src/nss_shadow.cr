# Shadow password database NSS functions.
#
# Implements _nss_exec_setspent, _nss_exec_endspent, _nss_exec_getspent_r,
# and _nss_exec_getspnam_r.
#
# Thread safety: @@ent_index is protected by @@mutex.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# License: MIT (see LICENSE file)

require "./nss_exec"

module NssExec
  module Shadow
    @@ent_index : Int64 = 0
    @@mutex : Mutex = Mutex.new(:reentrant)

    def self.setspent(stayopen : Int32) : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("setspent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.endspent : NssStatus
      @@mutex.synchronize do
        NssExec.exec_script("endspent")
        @@ent_index = 0
      end
      NssStatus::SUCCESS
    end

    def self.getspent(result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      @@mutex.synchronize do
        status, output = NssExec.exec_script_long("getspent", @@ent_index)
        return status unless status == NssStatus::SUCCESS
        return NssStatus::NOTFOUND unless output

        entry = ShadowEntry.parse(output)
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

    def self.getspnam(name : String, result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT, errnop : Int32*) : NssStatus
      status, output = NssExec.exec_script("getspnam", name)
      return status unless status == NssStatus::SUCCESS
      return NssStatus::NOTFOUND unless output

      entry = ShadowEntry.parse(output)
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

fun _nss_exec_setspent(stayopen : LibC::Int) : LibC::Int
  NssExec::Shadow.setspent(stayopen).value
rescue
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_endspent : LibC::Int
  NssExec::Shadow.endspent.value
rescue
  NssExec::NssStatus::SUCCESS.value
end

fun _nss_exec_getspent_r(result : LibC::Spwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  NssExec::Shadow.getspent(result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end

fun _nss_exec_getspnam_r(name : UInt8*, result : LibC::Spwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  name_str = String.new(name)
  NssExec::Shadow.getspnam(name_str, result, buffer, buflen, errnop).value
rescue
  errnop.value = LibC::ENOENT
  NssExec::NssStatus::UNAVAIL.value
end
