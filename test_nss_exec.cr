# Test program for NSS exec module
# This simulates what getent and other NSS clients do

require "./nss_types"
require "./nss_exec"
require "./nss_passwd"
require "./nss_group"
require "./nss_shadow"

module NssTest
  # Test passwd lookup by name
  def self.test_getpwnam(username : String)
    puts "Testing getpwnam for '#{username}'..."
    
    buffer = Pointer(UInt8).malloc(4096)
    result = Pointer(LibC::Passwd).malloc(1)
    errno = Pointer(Int32).malloc(1)
    
    status = NssExec::Passwd.getpwnam(username, result, buffer, 4096, errno)
    
    case status
    when NssExec::NssStatus::SUCCESS
      pwd = result.value
      puts "  Found user:"
      puts "    Username: #{String.new(pwd.pw_name)}"
      puts "    UID:      #{pwd.pw_uid}"
      puts "    GID:      #{pwd.pw_gid}"
      puts "    GECOS:    #{String.new(pwd.pw_gecos)}"
      puts "    Home:     #{String.new(pwd.pw_dir)}"
      puts "    Shell:    #{String.new(pwd.pw_shell)}"
    when NssExec::NssStatus::NOTFOUND
      puts "  User not found"
    when NssExec::NssStatus::UNAVAIL
      puts "  Service unavailable (errno: #{errno.value})"
    when NssExec::NssStatus::TRYAGAIN
      puts "  Temporary failure, try again (errno: #{errno.value})"
    end
    puts ""
  end
  
  # Test passwd lookup by UID
  def self.test_getpwuid(uid : UInt32)
    puts "Testing getpwuid for UID #{uid}..."
    
    buffer = Pointer(UInt8).malloc(4096)
    result = Pointer(LibC::Passwd).malloc(1)
    errno = Pointer(Int32).malloc(1)
    
    status = NssExec::Passwd.getpwuid(uid, result, buffer, 4096, errno)
    
    case status
    when NssExec::NssStatus::SUCCESS
      pwd = result.value
      puts "  Found user: #{String.new(pwd.pw_name)} (UID: #{pwd.pw_uid})"
    when NssExec::NssStatus::NOTFOUND
      puts "  UID not found"
    else
      puts "  Lookup failed"
    end
    puts ""
  end
  
  # Test group lookup by name
  def self.test_getgrnam(groupname : String)
    puts "Testing getgrnam for '#{groupname}'..."
    
    buffer = Pointer(UInt8).malloc(4096)
    result = Pointer(LibC::Group).malloc(1)
    errno = Pointer(Int32).malloc(1)
    
    status = NssExec::Group.getgrnam(groupname, result, buffer, 4096, errno)
    
    case status
    when NssExec::NssStatus::SUCCESS
      grp = result.value
      puts "  Found group:"
      puts "    Name: #{String.new(grp.gr_name)}"
      puts "    GID:  #{grp.gr_gid}"
    when NssExec::NssStatus::NOTFOUND
      puts "  Group not found"
    else
      puts "  Lookup failed"
    end
    puts ""
  end
  
  # Test script execution directly
  def self.test_script_exec
    puts "Testing direct script execution..."
    
    status, output = NssExec.exec_script("getpwnam", "testuser")
    puts "  Command: getpwnam testuser"
    puts "  Status:  #{status}"
    puts "  Output:  #{output || "(none)"}"
    puts ""
  end
end

# Main test runner
puts "=" * 60
puts "NSS Exec Crystal Implementation - Test Suite"
puts "=" * 60
puts ""
puts "Make sure #{NssExec::NSS_EXEC_SCRIPT} exists and is executable!"
puts ""

# Check if script exists
unless File.executable?(NssExec::NSS_EXEC_SCRIPT)
  puts "WARNING: #{NssExec::NSS_EXEC_SCRIPT} not found or not executable"
  puts "Create a test script first"
  puts ""
end

# Run tests
NssTest.test_script_exec
NssTest.test_getpwnam("testuser")
NssTest.test_getpwnam("root")
NssTest.test_getpwuid(5000)
NssTest.test_getgrnam("testgroup")

puts "=" * 60
puts "Tests complete!"
puts "=" * 60
