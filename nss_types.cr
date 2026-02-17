# NSS structure definitions for Crystal
# These map to the C structures used by glibc's NSS interface
#
# Copyright (c) 2025 [Your Name]
# Based on the original C implementation by Tyler Akins
# Original project: https://github.com/tests-always-included/libnss_exec
# License: MIT (see LICENSE file)

# Additional LibC functions we need for parsing
lib LibC
  fun strtoul(str : UInt8*, endptr : UInt8**, base : Int32) : UInt64
  fun strtok_r(str : UInt8*, delim : UInt8*, saveptr : UInt8**) : UInt8*
  fun strdup(str : UInt8*) : UInt8*
  fun strlen(str : UInt8*) : SizeT
  fun strcpy(dest : UInt8*, src : UInt8*) : UInt8*
end

module NssExec
  # NSS Status codes mapping (from nss.h)
  enum NssStatus : Int32
    SUCCESS   =  1  # Operation successful
    NOTFOUND  =  0  # Entry not found
    UNAVAIL   = -1  # Service unavailable
    TRYAGAIN  = -2  # Temporary failure, try again
  end
  
  # Helper class to manage buffer allocation for C strings
  # This ensures proper memory management when copying strings into
  # the buffer provided by glibc
  class BufferWriter
    @current : Pointer(UInt8)
    @remaining : Int32
    
    def initialize(@current : Pointer(UInt8), @remaining : Int32)
    end
    
    # Write a C string into the buffer and return a pointer to it
    # Returns nil if there's not enough space
    def write_cstring(cstr : UInt8*) : Pointer(UInt8)?
      return nil if cstr.null?
      
      length = LibC.strlen(cstr).to_i32
      needed = length + 1  # +1 for null terminator
      return nil if needed > @remaining
      
      # Copy string
      LibC.strcpy(@current, cstr)
      
      result = @current
      @current += needed
      @remaining -= needed
      
      result
    end
    
    # Write an array of string pointers (null-terminated)
    # tokens is a null-terminated array of C strings
    def write_string_array(tokens : Pointer(UInt8*), count : Int32) : Pointer(UInt8*)?
      # Calculate space needed
      array_size = (count + 1) * sizeof(Pointer(UInt8))
      
      # Calculate total string space
      total_str_size = 0
      count.times do |i|
        str = tokens[i]
        break if str.null?
        total_str_size += LibC.strlen(str).to_i32 + 1
      end
      
      total_needed = array_size + total_str_size
      return nil if total_needed > @remaining
      
      # Allocate array
      array_ptr = @current.as(Pointer(UInt8*))
      @current += array_size
      @remaining -= array_size
      
      # Copy each string
      count.times do |i|
        str = tokens[i]
        break if str.null?
        
        copied = write_cstring(str)
        return nil unless copied
        array_ptr[i] = copied
      end
      
      # Null-terminate array
      array_ptr[count] = Pointer(UInt8).null
      
      array_ptr
    end
  end
  
  # Wrapper for passwd entry with proper buffer management
  class PasswdEntry
    property name : UInt8*
    property passwd : UInt8*
    property uid : UInt32
    property gid : UInt32
    property gecos : UInt8*
    property dir : UInt8*
    property shell : UInt8*
    
    def initialize(@name, @passwd, @uid, @gid, @gecos, @dir, @shell)
    end
    
    # Parse from colon-delimited C string
    # Format: name:passwd:uid:gid:gecos:dir:shell
    def self.parse(output : String) : PasswdEntry?
      # Make a mutable copy for strtok_r
      output_copy = LibC.strdup(output.to_unsafe)
      return nil if output_copy.null?
      
      saveptr = Pointer(UInt8*).malloc(1)
      
      # Parse fields
      name = LibC.strtok_r(output_copy, ":".to_unsafe, saveptr)
      return nil if name.null?
      
      passwd = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if passwd.null?
      
      uid_str = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if uid_str.null?
      uid = LibC.strtoul(uid_str, nil, 10).to_u32
      
      gid_str = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if gid_str.null?
      gid = LibC.strtoul(gid_str, nil, 10).to_u32
      
      gecos = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if gecos.null?
      
      dir = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if dir.null?
      
      shell = LibC.strtok_r(nil, "\n".to_unsafe, saveptr)
      return nil if shell.null?
      
      new(name, passwd, uid, gid, gecos, dir, shell)
    end
    
    # Fill a C passwd structure, copying strings into the provided buffer
    def fill_c_struct(result : LibC::Passwd*, buffer : Pointer(UInt8), 
                      buffer_size : Int32) : Int32
      writer = BufferWriter.new(buffer, buffer_size)
      
      # Copy all strings to buffer
      pw_name = writer.write_cstring(name)
      pw_passwd = writer.write_cstring(passwd)
      pw_gecos = writer.write_cstring(gecos)
      pw_dir = writer.write_cstring(dir)
      pw_shell = writer.write_cstring(shell)
      
      return 1 unless pw_name && pw_passwd && pw_gecos && pw_dir && pw_shell
      
      # Fill structure
      result.value.pw_name = pw_name
      result.value.pw_passwd = pw_passwd
      result.value.pw_uid = uid
      result.value.pw_gid = gid
      result.value.pw_gecos = pw_gecos
      result.value.pw_dir = pw_dir
      result.value.pw_shell = pw_shell
      
      0  # Success
    end
  end
  
  # Wrapper for group entry with proper member array handling
  class GroupEntry
    property name : UInt8*
    property passwd : UInt8*
    property gid : UInt32
    property members : Pointer(UInt8*)
    property member_count : Int32
    
    def initialize(@name, @passwd, @gid, @members, @member_count)
    end
    
    # Parse from colon-delimited C string
    # Format: name:passwd:gid:member1,member2,member3
    def self.parse(output : String) : GroupEntry?
      output_copy = LibC.strdup(output.to_unsafe)
      return nil if output_copy.null?
      
      saveptr = Pointer(UInt8*).malloc(1)
      
      # Parse name, passwd, gid
      name = LibC.strtok_r(output_copy, ":".to_unsafe, saveptr)
      return nil if name.null?
      
      passwd = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if passwd.null?
      
      gid_str = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if gid_str.null?
      gid = LibC.strtoul(gid_str, nil, 10).to_u32
      
      # Parse members (optional)
      members_str = LibC.strtok_r(nil, "\n".to_unsafe, saveptr)
      
      if members_str.null? || LibC.strlen(members_str) == 0
        # No members
        return new(name, passwd, gid, Pointer(UInt8*).null, 0)
      end
      
      # Parse comma-separated members
      member_tokens = Pointer(UInt8*).malloc(100)  # Max 100 members
      member_count = 0
      member_saveptr = Pointer(UInt8*).malloc(1)
      
      token = LibC.strtok_r(members_str, ",".to_unsafe, member_saveptr)
      while !token.null? && member_count < 100
        member_tokens[member_count] = token
        member_count += 1
        token = LibC.strtok_r(nil, ",".to_unsafe, member_saveptr)
      end
      
      new(name, passwd, gid, member_tokens, member_count)
    end
    
    # Fill a C group structure with proper member array allocation
    def fill_c_struct(result : LibC::Group*, buffer : Pointer(UInt8),
                      buffer_size : Int32) : Int32
      writer = BufferWriter.new(buffer, buffer_size)
      
      # Copy name and passwd
      gr_name = writer.write_cstring(name)
      gr_passwd = writer.write_cstring(passwd)
      
      return 1 unless gr_name && gr_passwd
      
      # Fill structure
      result.value.gr_name = gr_name
      result.value.gr_passwd = gr_passwd
      result.value.gr_gid = gid
      
      # Handle members
      if member_count == 0
        empty_array = Pointer(UInt8*).malloc(1)
        empty_array[0] = Pointer(UInt8).null
        result.value.gr_mem = empty_array
      else
        mem_array = writer.write_string_array(members, member_count)
        return 1 unless mem_array
        result.value.gr_mem = mem_array
      end
      
      0  # Success
    end
  end
  
  # Wrapper for shadow entry
  class ShadowEntry
    property name : UInt8*
    property passwd : UInt8*
    property lastchg : Int64
    property min : Int64
    property max : Int64
    property warn : Int64
    property inact : Int64
    property expire : Int64
    property flag : UInt64
    
    def initialize(@name, @passwd, @lastchg = -1_i64, @min = -1_i64, 
                   @max = -1_i64, @warn = -1_i64, @inact = -1_i64, 
                   @expire = -1_i64, @flag = 0_u64)
    end
    
    # Parse from colon-delimited C string
    def self.parse(output : String) : ShadowEntry?
      output_copy = LibC.strdup(output.to_unsafe)
      return nil if output_copy.null?
      
      saveptr = Pointer(UInt8*).malloc(1)
      
      name = LibC.strtok_r(output_copy, ":".to_unsafe, saveptr)
      return nil if name.null?
      
      passwd = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      return nil if passwd.null?
      
      # Optional numeric fields
      lastchg = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      lastchg = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      min = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      min = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      max = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      max = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      warn = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      warn = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      inact = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      inact = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      expire = -1_i64
      token = LibC.strtok_r(nil, ":".to_unsafe, saveptr)
      expire = LibC.strtoul(token, nil, 10).to_i64 unless token.null?
      
      flag = 0_u64
      token = LibC.strtok_r(nil, ":\n".to_unsafe, saveptr)
      flag = LibC.strtoul(token, nil, 10) unless token.null?
      
      new(name, passwd, lastchg, min, max, warn, inact, expire, flag)
    end
    
    # Fill a C spwd structure
    def fill_c_struct(result : LibC::Spwd*, buffer : Pointer(UInt8),
                      buffer_size : Int32) : Int32
      writer = BufferWriter.new(buffer, buffer_size)
      
      sp_namp = writer.write_cstring(name)
      sp_pwdp = writer.write_cstring(passwd)
      
      return 1 unless sp_namp && sp_pwdp
      
      result.value.sp_namp = sp_namp
      result.value.sp_pwdp = sp_pwdp
      result.value.sp_lstchg = lastchg
      result.value.sp_min = min
      result.value.sp_max = max
      result.value.sp_warn = warn
      result.value.sp_inact = inact
      result.value.sp_expire = expire
      result.value.sp_flag = flag
      
      0  # Success
    end
  end
end

# Define NSS structs that aren't in LibC on this system
lib LibC
  struct Group
    gr_name : UInt8*
    gr_passwd : UInt8*
    gr_gid : GidT
    gr_mem : UInt8**
  end
  
  struct Spwd
    sp_namp : UInt8*
    sp_pwdp : UInt8*
    sp_lstchg : Int64
    sp_min : Int64
    sp_max : Int64
    sp_warn : Int64
    sp_inact : Int64
    sp_expire : Int64
    sp_flag : UInt64
  end
end
