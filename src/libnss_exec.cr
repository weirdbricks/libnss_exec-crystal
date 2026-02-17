# libnss_exec — NSS module that delegates lookups to an external script.
#
# This implementation uses ONLY raw C library calls. No Crystal String, Array,
# GC, or runtime. This is necessary because glibc loads NSS modules via
# dlopen(), and Crystal's runtime cannot be safely initialized in that context.
#
# All string operations use C's string.h functions (strlen, strcpy, strcmp, etc.)
# All memory is either stack-allocated or written into glibc's caller-provided
# buffer. Zero heap allocations.
#
# Copyright (c) 2025 libnss_exec-crystal contributors
# License: MIT (see LICENSE file)

# ─── C library bindings ──────────────────────────────────────────────────────

lib LibC
  # NSS structs — not in Crystal's stdlib
  struct Group
    gr_name : UInt8*
    gr_passwd : UInt8*
    gr_gid : GidT
    gr_mem : UInt8**
  end

  struct Spwd
    sp_namp : UInt8*
    sp_pwdp : UInt8*
    sp_lstchg : Long
    sp_min : Long
    sp_max : Long
    sp_warn : Long
    sp_inact : Long
    sp_expire : Long
    sp_flag : ULong
  end

  # C functions not in Crystal's stdlib
  fun execve(path : UInt8*, argv : UInt8**, envp : UInt8**) : Int
  fun strtoul(nptr : UInt8*, endptr : UInt8**, base : Int) : ULong
  fun strtol(nptr : UInt8*, endptr : UInt8**, base : Int) : Long
  fun strlen(s : UInt8*) : SizeT
  fun strcpy(dest : UInt8*, src : UInt8*) : UInt8*
  fun strcmp(s1 : UInt8*, s2 : UInt8*) : Int
  fun memcpy(dest : Void*, src : Void*, n : SizeT) : Void*
  fun memset(s : Void*, c : Int, n : SizeT) : Void*
end

# ─── Constants ───────────────────────────────────────────────────────────────

NSS_EXEC_SCRIPT = "/sbin/nss_exec"
READ_BUF_SIZE   = 4096

# NSS status codes
NSS_STATUS_TRYAGAIN = -2
NSS_STATUS_UNAVAIL  = -1
NSS_STATUS_NOTFOUND =  0
NSS_STATUS_SUCCESS  =  1

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Find the next occurrence of `delim` in `str`, starting at `pos`.
# Returns the index, or -1 if not found.
private def find_char(str : UInt8*, len : LibC::SizeT, pos : LibC::SizeT, delim : UInt8) : Int64
  i = pos
  while i < len
    return i.to_i64 if str[i] == delim
    i += 1
  end
  -1_i64
end

# Write a NUL-terminated C string into the buffer at *cursor.
# Advances cursor, decreases remaining. Returns pointer to the written string,
# or null if insufficient space.
private def buf_write_str(src : UInt8*, src_len : LibC::SizeT,
                          cursor : UInt8**, remaining : LibC::SizeT*) : UInt8*
  needed = src_len &+ 1 # +1 for NUL
  return Pointer(UInt8).null if needed > remaining.value

  ptr = cursor.value
  LibC.memcpy(ptr.as(Void*), src.as(Void*), src_len)
  ptr[src_len] = 0_u8

  cursor.value = cursor.value + needed
  remaining.value = remaining.value &- needed
  ptr
end

# Align cursor to pointer-size boundary. Returns false if not enough space.
private def buf_align(cursor : UInt8**, remaining : LibC::SizeT*) : Bool
  alignment = sizeof(Pointer(UInt8)).to_u64
  addr = cursor.value.address
  mask = alignment &- 1
  misalign = addr & mask
  return true if misalign == 0

  padding = alignment &- misalign
  return false if padding > remaining.value

  cursor.value = cursor.value + padding
  remaining.value = remaining.value &- padding
  true
end

# Parse a UInt32 from a C string segment. Returns {value, true} or {0, false}.
private def parse_u32(str : UInt8*, len : LibC::SizeT) : {UInt32, Bool}
  return {0_u32, false} if len == 0

  # Copy to a small stack buffer to NUL-terminate
  buf = uninitialized UInt8[32]
  copy_len = len < 31 ? len : 31_u64
  LibC.memcpy(buf.to_unsafe.as(Void*), str.as(Void*), copy_len)
  buf[copy_len] = 0_u8

  endptr = uninitialized UInt8*
  val = LibC.strtoul(buf.to_unsafe, pointerof(endptr), 10)
  # Check that we consumed the entire string
  consumed = (endptr.address - buf.to_unsafe.address).to_u64
  return {0_u32, false} unless consumed == copy_len
  return {0_u32, false} if val > UInt32::MAX.to_u64

  {val.to_u32, true}
end

# Parse a Int64 from a C string segment. Empty string → -1 (sentinel).
private def parse_i64_or_default(str : UInt8*, len : LibC::SizeT, default : Int64) : Int64
  return default if len == 0

  buf = uninitialized UInt8[32]
  copy_len = len < 31 ? len : 31_u64
  LibC.memcpy(buf.to_unsafe.as(Void*), str.as(Void*), copy_len)
  buf[copy_len] = 0_u8

  endptr = uninitialized UInt8*
  val = LibC.strtol(buf.to_unsafe, pointerof(endptr), 10)
  consumed = (endptr.address - buf.to_unsafe.address).to_u64
  return default unless consumed == copy_len

  val.to_i64
end

# Parse a UInt64 from a C string segment. Empty string → 0.
private def parse_u64_or_default(str : UInt8*, len : LibC::SizeT, default : UInt64) : UInt64
  return default if len == 0

  buf = uninitialized UInt8[32]
  copy_len = len < 31 ? len : 31_u64
  LibC.memcpy(buf.to_unsafe.as(Void*), str.as(Void*), copy_len)
  buf[copy_len] = 0_u8

  endptr = uninitialized UInt8*
  val = LibC.strtoul(buf.to_unsafe, pointerof(endptr), 10)
  consumed = (endptr.address - buf.to_unsafe.address).to_u64
  return default unless consumed == copy_len

  val.to_u64
end

# ─── Script execution ────────────────────────────────────────────────────────

# Execute /sbin/nss_exec with command + optional argument via fork/execve.
# Reads one line of output into `out_buf` (caller-provided, `out_size` bytes).
# Returns {nss_status, bytes_read}.
private def exec_script(command : UInt8*, argument : UInt8*,
                        out_buf : UInt8*, out_size : LibC::SizeT) : {Int32, LibC::SizeT}
  return {NSS_STATUS_UNAVAIL, 0_u64} if LibC.access(NSS_EXEC_SCRIPT.to_unsafe, LibC::X_OK) != 0

  pipefd = StaticArray(Int32, 2).new(0)
  return {NSS_STATUS_UNAVAIL, 0_u64} if LibC.pipe(pipefd) != 0

  pid = LibC.fork
  if pid < 0
    LibC.close(pipefd[0])
    LibC.close(pipefd[1])
    return {NSS_STATUS_UNAVAIL, 0_u64}
  end

  if pid == 0
    # ── Child ────────────────────────────────────────────────────────
    LibC.close(pipefd[0])
    LibC.dup2(pipefd[1], 1)
    LibC.close(pipefd[1])

    if argument.null?
      argv = uninitialized UInt8*[4]
      argv[0] = NSS_EXEC_SCRIPT.to_unsafe
      argv[1] = command
      argv[2] = Pointer(UInt8).null
      argv[3] = Pointer(UInt8).null
    else
      argv = uninitialized UInt8*[4]
      argv[0] = NSS_EXEC_SCRIPT.to_unsafe
      argv[1] = command
      argv[2] = argument
      argv[3] = Pointer(UInt8).null
    end

    envp = uninitialized UInt8*[2]
    envp[0] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin".to_unsafe
    envp[1] = Pointer(UInt8).null

    LibC.execve(NSS_EXEC_SCRIPT.to_unsafe, argv.to_unsafe, envp.to_unsafe)
    LibC._exit(127)
  end

  # ── Parent ──────────────────────────────────────────────────────────
  LibC.close(pipefd[1])

  total = 0_u64
  if !out_buf.null? && out_size > 1
    loop do
      break if total &+ 1 >= out_size # wrapping add to avoid overflow
      remaining = out_size &- total &- 1
      break if remaining == 0
      bytes = LibC.read(pipefd[0], (out_buf + total).as(Void*), remaining)
      break if bytes <= 0
      total = total &+ bytes.to_u64
    end
    out_buf[total] = 0_u8

    # Strip trailing newline
    while total > 0 && (out_buf[total &- 1] == '\n'.ord.to_u8 || out_buf[total &- 1] == '\r'.ord.to_u8)
      total = total &- 1
      out_buf[total] = 0_u8
    end
  else
    # No output buffer — just drain the pipe
    drain = uninitialized UInt8[256]
    loop do
      bytes = LibC.read(pipefd[0], drain.to_unsafe.as(Void*), 256_u64)
      break if bytes <= 0
    end
  end

  LibC.close(pipefd[0])

  wait_status = 0
  LibC.waitpid(pid, pointerof(wait_status), 0)
  exit_code = (wait_status >> 8) & 0xFF

  status = case exit_code
           when 0 then NSS_STATUS_SUCCESS
           when 1 then NSS_STATUS_NOTFOUND
           when 2 then NSS_STATUS_TRYAGAIN
           else        NSS_STATUS_UNAVAIL
           end

  {status, total}
end

# Convenience: format an Int64 as a decimal string into a stack buffer.
private def i64_to_s(value : Int64, buf : UInt8*, buf_size : LibC::SizeT) : UInt8*
  return buf if buf_size == 0

  negative = value < 0
  v = negative ? (0_i64 - value) : value # Can't use .abs — no runtime

  # Write digits backwards
  pos = buf_size &- 1
  buf[pos] = 0_u8
  if v == 0
    pos = pos &- 1
    buf[pos] = '0'.ord.to_u8
  else
    while v > 0 && pos > 0
      pos = pos &- 1
      buf[pos] = ('0'.ord.to_u8 &+ (v % 10).to_u8)
      v = v // 10
    end
  end
  if negative && pos > 0
    pos = pos &- 1
    buf[pos] = '-'.ord.to_u8
  end

  buf + pos
end

# ─── Field splitter ──────────────────────────────────────────────────────────

# Given a line like "name:passwd:uid:gid:gecos:dir:shell", find the start and
# length of field N (0-indexed), split by ':'. Returns {ptr, len} or {null, 0}.
private def get_field(line : UInt8*, line_len : LibC::SizeT, field : Int32) : {UInt8*, LibC::SizeT}
  pos = 0_u64
  current_field = 0

  while pos <= line_len
    if current_field == field
      # Find end of this field
      end_pos = pos
      while end_pos < line_len && line[end_pos] != ':'.ord.to_u8
        end_pos += 1
      end
      return {line + pos, end_pos &- pos}
    end

    # Skip to next ':'
    while pos < line_len && line[pos] != ':'.ord.to_u8
      pos += 1
    end
    pos += 1 # skip the ':'
    current_field += 1
  end

  {Pointer(UInt8).null, 0_u64}
end

# Count the number of ':' delimiters to know how many fields.
private def count_fields(line : UInt8*, line_len : LibC::SizeT) : Int32
  return 0 if line_len == 0
  count = 1
  i = 0_u64
  while i < line_len
    count += 1 if line[i] == ':'.ord.to_u8
    i += 1
  end
  count
end

# ─── Passwd ──────────────────────────────────────────────────────────────────

private def fill_passwd(line : UInt8*, line_len : LibC::SizeT,
                        result : LibC::Passwd*, buffer : UInt8*,
                        buflen : LibC::SizeT, errnop : LibC::Int*) : Int32
  return NSS_STATUS_UNAVAIL if count_fields(line, line_len) < 7

  f_name, f_name_len = get_field(line, line_len, 0)
  f_passwd, f_passwd_len = get_field(line, line_len, 1)
  f_uid, f_uid_len = get_field(line, line_len, 2)
  f_gid, f_gid_len = get_field(line, line_len, 3)
  f_gecos, f_gecos_len = get_field(line, line_len, 4)
  f_dir, f_dir_len = get_field(line, line_len, 5)
  f_shell, f_shell_len = get_field(line, line_len, 6)

  uid_val, uid_ok = parse_u32(f_uid, f_uid_len)
  gid_val, gid_ok = parse_u32(f_gid, f_gid_len)
  unless uid_ok && gid_ok
    errnop.value = LibC::ENOENT
    return NSS_STATUS_UNAVAIL
  end

  cursor = buffer
  remaining = buflen

  pw_name = buf_write_str(f_name, f_name_len, pointerof(cursor), pointerof(remaining))
  pw_passwd = buf_write_str(f_passwd, f_passwd_len, pointerof(cursor), pointerof(remaining))
  pw_gecos = buf_write_str(f_gecos, f_gecos_len, pointerof(cursor), pointerof(remaining))
  pw_dir = buf_write_str(f_dir, f_dir_len, pointerof(cursor), pointerof(remaining))
  pw_shell = buf_write_str(f_shell, f_shell_len, pointerof(cursor), pointerof(remaining))

  if pw_name.null? || pw_passwd.null? || pw_gecos.null? || pw_dir.null? || pw_shell.null?
    errnop.value = LibC::ERANGE
    return NSS_STATUS_TRYAGAIN
  end

  result.value.pw_name = pw_name
  result.value.pw_passwd = pw_passwd
  result.value.pw_uid = uid_val
  result.value.pw_gid = gid_val
  result.value.pw_gecos = pw_gecos
  result.value.pw_dir = pw_dir
  result.value.pw_shell = pw_shell

  NSS_STATUS_SUCCESS
end

# ─── Group ───────────────────────────────────────────────────────────────────

private def fill_group(line : UInt8*, line_len : LibC::SizeT,
                       result : LibC::Group*, buffer : UInt8*,
                       buflen : LibC::SizeT, errnop : LibC::Int*) : Int32
  nfields = count_fields(line, line_len)
  return NSS_STATUS_UNAVAIL if nfields < 3

  f_name, f_name_len = get_field(line, line_len, 0)
  f_passwd, f_passwd_len = get_field(line, line_len, 1)
  f_gid, f_gid_len = get_field(line, line_len, 2)

  gid_val, gid_ok = parse_u32(f_gid, f_gid_len)
  unless gid_ok
    errnop.value = LibC::ENOENT
    return NSS_STATUS_UNAVAIL
  end

  # Parse members field (field 3, comma-separated)
  f_mem = Pointer(UInt8).null
  f_mem_len = 0_u64
  if nfields >= 4
    f_mem, f_mem_len = get_field(line, line_len, 3)
  end

  # Count members
  num_members = 0
  if !f_mem.null? && f_mem_len > 0
    num_members = 1
    i = 0_u64
    while i < f_mem_len
      num_members += 1 if f_mem[i] == ','.ord.to_u8
      i += 1
    end
  end

  cursor = buffer
  remaining = buflen

  gr_name = buf_write_str(f_name, f_name_len, pointerof(cursor), pointerof(remaining))
  gr_passwd = buf_write_str(f_passwd, f_passwd_len, pointerof(cursor), pointerof(remaining))
  return NSS_STATUS_TRYAGAIN if gr_name.null? || gr_passwd.null?

  # Align for pointer array
  unless buf_align(pointerof(cursor), pointerof(remaining))
    errnop.value = LibC::ERANGE
    return NSS_STATUS_TRYAGAIN
  end

  # Allocate pointer array: (num_members + 1) pointers (NULL terminated)
  array_bytes = ((num_members &+ 1) &* sizeof(Pointer(UInt8))).to_u64
  if array_bytes > remaining
    errnop.value = LibC::ERANGE
    return NSS_STATUS_TRYAGAIN
  end
  gr_mem = cursor.as(UInt8**)
  cursor = cursor + array_bytes
  remaining = remaining &- array_bytes

  # Write each member string
  if !f_mem.null? && f_mem_len > 0
    mem_idx = 0
    mem_start = 0_u64
    i = 0_u64
    while i <= f_mem_len
      if i == f_mem_len || f_mem[i] == ','.ord.to_u8
        mem_len = i &- mem_start
        if mem_len > 0
          ptr = buf_write_str(f_mem + mem_start, mem_len, pointerof(cursor), pointerof(remaining))
          if ptr.null?
            errnop.value = LibC::ERANGE
            return NSS_STATUS_TRYAGAIN
          end
          gr_mem[mem_idx] = ptr
          mem_idx += 1
        end
        mem_start = i + 1
      end
      i += 1
    end
    gr_mem[mem_idx] = Pointer(UInt8).null
  else
    gr_mem[0] = Pointer(UInt8).null
  end

  result.value.gr_name = gr_name
  result.value.gr_passwd = gr_passwd
  result.value.gr_gid = gid_val
  result.value.gr_mem = gr_mem

  NSS_STATUS_SUCCESS
end

# ─── Shadow ──────────────────────────────────────────────────────────────────

private def fill_shadow(line : UInt8*, line_len : LibC::SizeT,
                        result : LibC::Spwd*, buffer : UInt8*,
                        buflen : LibC::SizeT, errnop : LibC::Int*) : Int32
  return NSS_STATUS_UNAVAIL if count_fields(line, line_len) < 2

  f_name, f_name_len = get_field(line, line_len, 0)
  f_passwd, f_passwd_len = get_field(line, line_len, 1)

  cursor = buffer
  remaining = buflen

  sp_namp = buf_write_str(f_name, f_name_len, pointerof(cursor), pointerof(remaining))
  sp_pwdp = buf_write_str(f_passwd, f_passwd_len, pointerof(cursor), pointerof(remaining))

  if sp_namp.null? || sp_pwdp.null?
    errnop.value = LibC::ERANGE
    return NSS_STATUS_TRYAGAIN
  end

  f2, f2_len = get_field(line, line_len, 2)
  f3, f3_len = get_field(line, line_len, 3)
  f4, f4_len = get_field(line, line_len, 4)
  f5, f5_len = get_field(line, line_len, 5)
  f6, f6_len = get_field(line, line_len, 6)
  f7, f7_len = get_field(line, line_len, 7)
  f8, f8_len = get_field(line, line_len, 8)

  result.value.sp_namp = sp_namp
  result.value.sp_pwdp = sp_pwdp
  result.value.sp_lstchg = LibC::Long.new(parse_i64_or_default(f2, f2_len, -1_i64))
  result.value.sp_min = LibC::Long.new(parse_i64_or_default(f3, f3_len, -1_i64))
  result.value.sp_max = LibC::Long.new(parse_i64_or_default(f4, f4_len, -1_i64))
  result.value.sp_warn = LibC::Long.new(parse_i64_or_default(f5, f5_len, -1_i64))
  result.value.sp_inact = LibC::Long.new(parse_i64_or_default(f6, f6_len, -1_i64))
  result.value.sp_expire = LibC::Long.new(parse_i64_or_default(f7, f7_len, -1_i64))
  result.value.sp_flag = LibC::ULong.new(parse_u64_or_default(f8, f8_len, 0_u64))

  NSS_STATUS_SUCCESS
end

# ─── Shared state for enumeration ────────────────────────────────────────────
module NssExecState
  @@passwd_index : Int64 = 0_i64
  @@group_index : Int64 = 0_i64
  @@shadow_index : Int64 = 0_i64

  def self.passwd_index
    @@passwd_index
  end

  def self.passwd_index=(v : Int64)
    @@passwd_index = v
  end

  def self.group_index
    @@group_index
  end

  def self.group_index=(v : Int64)
    @@group_index = v
  end

  def self.shadow_index
    @@shadow_index
  end

  def self.shadow_index=(v : Int64)
    @@shadow_index = v
  end
end

# ─── Generic lookup helper ───────────────────────────────────────────────────

private def do_lookup(command : UInt8*, argument : UInt8*) : {Int32, UInt8*, LibC::SizeT}
  buf = Pointer(UInt8).malloc(READ_BUF_SIZE)
  status, bytes = exec_script(command, argument, buf, READ_BUF_SIZE.to_u64)
  if status == NSS_STATUS_SUCCESS && bytes > 0
    {status, buf, bytes}
  else
    {status, Pointer(UInt8).null, 0_u64}
  end
end

# ─── C-exported entry points ─────────────────────────────────────────────────

# ── Passwd ──

fun _nss_exec_setpwent(stayopen : LibC::Int) : LibC::Int
  exec_script("setpwent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.passwd_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_endpwent : LibC::Int
  exec_script("endpwent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.passwd_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_getpwent_r(result : LibC::Passwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  arg_buf = uninitialized UInt8[32]
  arg_str = i64_to_s(NssExecState.passwd_index, arg_buf.to_unsafe, 32_u64)

  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getpwent".to_unsafe, arg_str, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  rc = fill_passwd(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
  NssExecState.passwd_index = NssExecState.passwd_index &+ 1 if rc == NSS_STATUS_SUCCESS
  rc
end

fun _nss_exec_getpwnam_r(name : UInt8*, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getpwnam".to_unsafe, name, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  fill_passwd(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
end

fun _nss_exec_getpwuid_r(uid : LibC::UidT, result : LibC::Passwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  arg_buf = uninitialized UInt8[32]
  arg_str = i64_to_s(uid.to_i64, arg_buf.to_unsafe, 32_u64)

  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getpwuid".to_unsafe, arg_str, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  fill_passwd(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
end

# ── Group ──

fun _nss_exec_setgrent(stayopen : LibC::Int) : LibC::Int
  exec_script("setgrent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.group_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_endgrent : LibC::Int
  exec_script("endgrent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.group_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_getgrent_r(result : LibC::Group*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  arg_buf = uninitialized UInt8[32]
  arg_str = i64_to_s(NssExecState.group_index, arg_buf.to_unsafe, 32_u64)

  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getgrent".to_unsafe, arg_str, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  rc = fill_group(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
  NssExecState.group_index = NssExecState.group_index &+ 1 if rc == NSS_STATUS_SUCCESS
  rc
end

fun _nss_exec_getgrnam_r(name : UInt8*, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getgrnam".to_unsafe, name, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  fill_group(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
end

fun _nss_exec_getgrgid_r(gid : LibC::GidT, result : LibC::Group*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  arg_buf = uninitialized UInt8[32]
  arg_str = i64_to_s(gid.to_i64, arg_buf.to_unsafe, 32_u64)

  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getgrgid".to_unsafe, arg_str, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  fill_group(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
end

# ── Shadow ──

fun _nss_exec_setspent(stayopen : LibC::Int) : LibC::Int
  exec_script("setspent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.shadow_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_endspent : LibC::Int
  exec_script("endspent".to_unsafe, Pointer(UInt8).null, Pointer(UInt8).null, 0_u64)
  NssExecState.shadow_index = 0_i64
  NSS_STATUS_SUCCESS
end

fun _nss_exec_getspent_r(result : LibC::Spwd*, buffer : UInt8*,
                         buflen : LibC::SizeT, errnop : LibC::Int*) : LibC::Int
  arg_buf = uninitialized UInt8[32]
  arg_str = i64_to_s(NssExecState.shadow_index, arg_buf.to_unsafe, 32_u64)

  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getspent".to_unsafe, arg_str, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  rc = fill_shadow(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
  NssExecState.shadow_index = NssExecState.shadow_index &+ 1 if rc == NSS_STATUS_SUCCESS
  rc
end

fun _nss_exec_getspnam_r(name : UInt8*, result : LibC::Spwd*,
                         buffer : UInt8*, buflen : LibC::SizeT,
                         errnop : LibC::Int*) : LibC::Int
  out_buf = uninitialized UInt8[READ_BUF_SIZE]
  status, bytes = exec_script("getspnam".to_unsafe, name, out_buf.to_unsafe, READ_BUF_SIZE.to_u64)
  return status unless status == NSS_STATUS_SUCCESS
  return NSS_STATUS_NOTFOUND if bytes == 0

  fill_shadow(out_buf.to_unsafe, bytes, result, buffer, buflen, errnop)
end
