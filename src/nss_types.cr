# NSS structure definitions for Crystal.
#
# These map to the C structures used by glibc's NSS interface.
# Entry types (PasswdEntry, GroupEntry, ShadowEntry) hold Crystal Strings
# and only write into raw C memory in their `fill_c_struct` methods,
# avoiding lifetime / GC issues with raw pointers.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# Based on the original C implementation by Tyler Akins
# Original project: https://github.com/tests-always-included/libnss_exec
# License: MIT (see LICENSE file)

# glibc structures not always present in Crystal's LibC bindings.
lib LibC
  struct Group
    gr_name   : UInt8*
    gr_passwd : UInt8*
    gr_gid    : GidT
    gr_mem    : UInt8**
  end

  struct Spwd
    sp_namp   : UInt8*
    sp_pwdp   : UInt8*
    sp_lstchg : Long
    sp_min    : Long
    sp_max    : Long
    sp_warn   : Long
    sp_inact  : Long
    sp_expire : Long
    sp_flag   : ULong
  end
end

module NssExec
  # NSS status codes as defined in <nss.h>.
  # glibc expects these from every _nss_*_* entry point.
  enum NssStatus : Int32
    TRYAGAIN = -2 # Temporary failure; retry (with larger buffer if ERANGE)
    UNAVAIL  = -1 # Service unavailable
    NOTFOUND =  0 # Entry not found
    SUCCESS  =  1 # Found
  end

  # Manages writing C strings and pointer arrays into a caller-provided buffer.
  #
  # glibc's reentrant (_r) NSS functions hand us a buffer + size. Every string
  # the module returns **must** live inside that buffer. Pointing into Crystal's
  # GC heap would cause use-after-free once the GC collects.
  #
  # BufferWriter tracks a cursor and remaining space, performing bounds-checked
  # copies. Any write that would exceed the buffer returns `nil`, allowing the
  # caller to return ERANGE / TRYAGAIN so glibc retries with a bigger buffer.
  struct BufferWriter
    @cursor : Pointer(UInt8)
    @remaining : LibC::SizeT

    def initialize(buffer : Pointer(UInt8), size : LibC::SizeT)
      @cursor = buffer
      @remaining = size
    end

    # Advance the cursor to the next `alignment`-byte boundary (must be a
    # power of two). Required before writing pointer arrays to avoid SIGBUS
    # on strict-alignment architectures (ARM, SPARC, etc.).
    private def align_to(alignment : LibC::SizeT) : Bool
      mask = alignment &- 1 # e.g. 8 - 1 = 7 = 0b0111
      misalign = @cursor.address & mask
      return true if misalign == 0

      padding = alignment &- misalign
      return false if padding > @remaining

      @cursor += padding
      @remaining &-= padding
      true
    end

    # Copy a Crystal String into the buffer as a NUL-terminated C string.
    # Returns a pointer within the buffer, or nil if there isn't enough space.
    def write_string(str : String) : Pointer(UInt8)?
      needed = str.bytesize.to_u64 &+ 1 # +1 for NUL
      return nil if needed > @remaining

      str.to_slice.copy_to(@cursor, str.bytesize)
      @cursor[str.bytesize] = 0_u8

      ptr = @cursor
      @cursor += needed
      @remaining &-= needed
      ptr
    end

    # Write a NULL-terminated array of C-string pointers into the buffer.
    # Each string in `strings` is copied, and a pointer table (NULL-terminated)
    # is written before them.
    #
    # Memory layout inside the buffer:
    #   [ptr0][ptr1]...[ptrN][NULL] [str0\0] [str1\0] ... [strN\0]
    #
    # Returns a pointer to the array, or nil on insufficient space.
    def write_string_array(strings : Array(String)) : Pointer(UInt8*)?
      return nil unless align_to(sizeof(Pointer(UInt8)).to_u64)

      # (N + 1) pointers: one per string plus the NULL terminator
      array_bytes = ((strings.size &+ 1) &* sizeof(Pointer(UInt8))).to_u64
      return nil if array_bytes > @remaining

      array_ptr = @cursor.as(Pointer(UInt8*))
      @cursor += array_bytes
      @remaining &-= array_bytes

      strings.each_with_index do |s, i|
        ptr = write_string(s)
        return nil unless ptr
        array_ptr[i] = ptr
      end

      array_ptr[strings.size] = Pointer(UInt8).null
      array_ptr
    end
  end

  # ---------------------------------------------------------------------------
  # Parsed entry types
  #
  # These hold plain Crystal Strings. Parsing happens entirely in Crystal-land
  # (no strtok_r, no strdup, no manual free). Raw C buffers are only touched
  # in fill_c_struct.
  # ---------------------------------------------------------------------------

  # Parsed passwd entry.
  # Format: name:passwd:uid:gid:gecos:dir:shell
  record PasswdEntry,
    name : String,
    passwd : String,
    uid : UInt32,
    gid : UInt32,
    gecos : String,
    dir : String,
    shell : String do
    def self.parse(output : String) : PasswdEntry?
      parts = output.strip.split(':', limit: 7)
      return nil unless parts.size == 7

      uid = parts[2].to_u32?(base: 10)
      gid = parts[3].to_u32?(base: 10)
      return nil unless uid && gid

      new(parts[0], parts[1], uid, gid, parts[4], parts[5], parts[6])
    end

    # Copy all fields into a glibc `struct passwd` using `buffer`.
    # Returns 0 on success, 1 if the buffer is too small (ERANGE).
    def fill_c_struct(result : LibC::Passwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT) : Int32
      writer = BufferWriter.new(buffer, buflen)

      pw_name = writer.write_string(name)
      pw_passwd = writer.write_string(passwd)
      pw_gecos = writer.write_string(gecos)
      pw_dir = writer.write_string(dir)
      pw_shell = writer.write_string(shell)

      return 1 unless pw_name && pw_passwd && pw_gecos && pw_dir && pw_shell

      result.value.pw_name = pw_name
      result.value.pw_passwd = pw_passwd
      result.value.pw_uid = uid
      result.value.pw_gid = gid
      result.value.pw_gecos = pw_gecos
      result.value.pw_dir = pw_dir
      result.value.pw_shell = pw_shell
      0
    end
  end

  # Parsed group entry.
  # Format: name:passwd:gid:member1,member2,...
  record GroupEntry,
    name : String,
    passwd : String,
    gid : UInt32,
    members : Array(String) do
    def self.parse(output : String) : GroupEntry?
      parts = output.strip.split(':', limit: 4)
      return nil unless parts.size >= 3

      gid = parts[2].to_u32?(base: 10)
      return nil unless gid

      members = if parts.size >= 4 && !parts[3].empty?
                  parts[3].split(',').reject(&.empty?)
                else
                  [] of String
                end

      new(parts[0], parts[1], gid, members)
    end

    def fill_c_struct(result : LibC::Group*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT) : Int32
      writer = BufferWriter.new(buffer, buflen)

      gr_name = writer.write_string(name)
      gr_passwd = writer.write_string(passwd)
      return 1 unless gr_name && gr_passwd

      gr_mem = writer.write_string_array(members)
      return 1 unless gr_mem

      result.value.gr_name = gr_name
      result.value.gr_passwd = gr_passwd
      result.value.gr_gid = gid
      result.value.gr_mem = gr_mem
      0
    end
  end

  # Parsed shadow entry.
  # Format: name:passwd:lastchg:min:max:warn:inact:expire:flag
  # Empty numeric fields default to -1 (unknown), matching glibc convention.
  record ShadowEntry,
    name : String,
    passwd : String,
    lastchg : Int64 = -1_i64,
    min : Int64 = -1_i64,
    max : Int64 = -1_i64,
    warn : Int64 = -1_i64,
    inact : Int64 = -1_i64,
    expire : Int64 = -1_i64,
    flag : UInt64 = 0_u64 do
    def self.parse(output : String) : ShadowEntry?
      parts = output.strip.split(':', limit: 9)
      return nil unless parts.size >= 2

      new(
        name: parts[0],
        passwd: parts[1],
        lastchg: parts[2]?.try(&.to_i64?) || -1_i64,
        min: parts[3]?.try(&.to_i64?) || -1_i64,
        max: parts[4]?.try(&.to_i64?) || -1_i64,
        warn: parts[5]?.try(&.to_i64?) || -1_i64,
        inact: parts[6]?.try(&.to_i64?) || -1_i64,
        expire: parts[7]?.try(&.to_i64?) || -1_i64,
        flag: parts[8]?.try(&.to_u64?) || 0_u64,
      )
    end

    def fill_c_struct(result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buflen : LibC::SizeT) : Int32
      writer = BufferWriter.new(buffer, buflen)

      sp_namp = writer.write_string(name)
      sp_pwdp = writer.write_string(passwd)
      return 1 unless sp_namp && sp_pwdp

      result.value.sp_namp = sp_namp
      result.value.sp_pwdp = sp_pwdp
      result.value.sp_lstchg = LibC::Long.new(lastchg)
      result.value.sp_min = LibC::Long.new(min)
      result.value.sp_max = LibC::Long.new(max)
      result.value.sp_warn = LibC::Long.new(warn)
      result.value.sp_inact = LibC::Long.new(inact)
      result.value.sp_expire = LibC::Long.new(expire)
      result.value.sp_flag = LibC::ULong.new(flag)
      0
    end
  end
end
