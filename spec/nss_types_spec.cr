require "spec"
require "../src/nss_types"

describe NssExec::PasswdEntry do
  describe ".parse" do
    it "parses a well-formed passwd line" do
      entry = NssExec::PasswdEntry.parse("alice:x:1001:1001:Alice Smith:/home/alice:/bin/zsh")
      entry.should_not be_nil
      entry = entry.not_nil!
      entry.name.should eq "alice"
      entry.passwd.should eq "x"
      entry.uid.should eq 1001_u32
      entry.gid.should eq 1001_u32
      entry.gecos.should eq "Alice Smith"
      entry.dir.should eq "/home/alice"
      entry.shell.should eq "/bin/zsh"
    end

    it "returns nil for too few fields" do
      NssExec::PasswdEntry.parse("alice:x:1001").should be_nil
    end

    it "returns nil for non-numeric UID" do
      NssExec::PasswdEntry.parse("alice:x:abc:1001:G:/h:/s").should be_nil
    end

    it "returns nil for non-numeric GID" do
      NssExec::PasswdEntry.parse("alice:x:1001:abc:G:/h:/s").should be_nil
    end

    it "strips trailing whitespace/newlines" do
      entry = NssExec::PasswdEntry.parse("bob:x:500:500:Bob:/home/bob:/bin/bash\n")
      entry.should_not be_nil
      entry.not_nil!.shell.should eq "/bin/bash"
    end

    it "handles empty gecos field" do
      entry = NssExec::PasswdEntry.parse("svc:x:999:999::/var/svc:/usr/sbin/nologin")
      entry.should_not be_nil
      entry.not_nil!.gecos.should eq ""
    end

    it "returns nil on empty string" do
      NssExec::PasswdEntry.parse("").should be_nil
    end

    it "handles maximum UID/GID values" do
      entry = NssExec::PasswdEntry.parse("nobody:x:4294967294:4294967294:Nobody:/:/sbin/nologin")
      entry.should_not be_nil
      entry.not_nil!.uid.should eq 4294967294_u32
    end
  end

  describe "#fill_c_struct" do
    it "fills a passwd struct correctly" do
      entry = NssExec::PasswdEntry.parse("alice:x:1001:1001:Alice:/home/alice:/bin/zsh").not_nil!
      buffer = Pointer(UInt8).malloc(4096)
      result = Pointer(LibC::Passwd).malloc(1)

      ret = entry.fill_c_struct(result, buffer, 4096_u64)
      ret.should eq 0

      String.new(result.value.pw_name).should eq "alice"
      String.new(result.value.pw_passwd).should eq "x"
      result.value.pw_uid.should eq 1001
      result.value.pw_gid.should eq 1001
      String.new(result.value.pw_gecos).should eq "Alice"
      String.new(result.value.pw_dir).should eq "/home/alice"
      String.new(result.value.pw_shell).should eq "/bin/zsh"
    end

    it "returns 1 (ERANGE) if buffer is too small" do
      entry = NssExec::PasswdEntry.parse("alice:x:1001:1001:Alice:/home/alice:/bin/zsh").not_nil!
      buffer = Pointer(UInt8).malloc(10)
      result = Pointer(LibC::Passwd).malloc(1)

      ret = entry.fill_c_struct(result, buffer, 10_u64)
      ret.should eq 1
    end
  end
end

describe NssExec::GroupEntry do
  describe ".parse" do
    it "parses a group with members" do
      entry = NssExec::GroupEntry.parse("devs:x:2000:alice,bob,charlie")
      entry.should_not be_nil
      entry = entry.not_nil!
      entry.name.should eq "devs"
      entry.gid.should eq 2000_u32
      entry.members.should eq ["alice", "bob", "charlie"]
    end

    it "parses a group with no members" do
      entry = NssExec::GroupEntry.parse("empty:x:3000:")
      entry.should_not be_nil
      entry.not_nil!.members.should be_empty
    end

    it "parses a group with the members field entirely absent" do
      entry = NssExec::GroupEntry.parse("nofield:x:3001")
      entry.should_not be_nil
      entry.not_nil!.members.should be_empty
    end

    it "handles single member" do
      entry = NssExec::GroupEntry.parse("solo:x:4000:alice")
      entry.should_not be_nil
      entry.not_nil!.members.should eq ["alice"]
    end

    it "rejects trailing empty members from 'alice,'" do
      entry = NssExec::GroupEntry.parse("g:x:1:alice,")
      entry.should_not be_nil
      entry.not_nil!.members.should eq ["alice"]
    end

    it "returns nil for non-numeric GID" do
      NssExec::GroupEntry.parse("g:x:abc:alice").should be_nil
    end

    it "returns nil on empty input" do
      NssExec::GroupEntry.parse("").should be_nil
    end
  end

  describe "#fill_c_struct" do
    it "fills a group struct with members" do
      entry = NssExec::GroupEntry.parse("devs:x:2000:alice,bob").not_nil!
      buffer = Pointer(UInt8).malloc(4096)
      result = Pointer(LibC::Group).malloc(1)

      ret = entry.fill_c_struct(result, buffer, 4096_u64)
      ret.should eq 0

      String.new(result.value.gr_name).should eq "devs"
      result.value.gr_gid.should eq 2000

      # Check members array
      mem = result.value.gr_mem
      String.new(mem[0]).should eq "alice"
      String.new(mem[1]).should eq "bob"
      mem[2].null?.should be_true # NULL terminator
    end

    it "fills an empty-member group with a NULL-terminated array" do
      entry = NssExec::GroupEntry.parse("empty:x:3000:").not_nil!
      buffer = Pointer(UInt8).malloc(4096)
      result = Pointer(LibC::Group).malloc(1)

      ret = entry.fill_c_struct(result, buffer, 4096_u64)
      ret.should eq 0

      result.value.gr_mem[0].null?.should be_true
    end
  end
end

describe NssExec::ShadowEntry do
  describe ".parse" do
    it "parses a full shadow line" do
      entry = NssExec::ShadowEntry.parse("alice:$6$hash:18500:0:99999:7:::")
      entry.should_not be_nil
      entry = entry.not_nil!
      entry.name.should eq "alice"
      entry.passwd.should eq "$6$hash"
      entry.lastchg.should eq 18500_i64
      entry.min.should eq 0_i64
      entry.max.should eq 99999_i64
      entry.warn.should eq 7_i64
      entry.inact.should eq(-1_i64)  # empty → -1
      entry.expire.should eq(-1_i64)
      entry.flag.should eq 0_u64
    end

    it "handles minimal shadow line (just name:passwd)" do
      entry = NssExec::ShadowEntry.parse("bob:!")
      entry.should_not be_nil
      entry = entry.not_nil!
      entry.name.should eq "bob"
      entry.passwd.should eq "!"
      entry.lastchg.should eq(-1_i64)
    end

    it "returns nil on empty input" do
      NssExec::ShadowEntry.parse("").should be_nil
    end
  end

  describe "#fill_c_struct" do
    it "fills a spwd struct" do
      entry = NssExec::ShadowEntry.parse("alice:!:18000:0:99999:7:::").not_nil!
      buffer = Pointer(UInt8).malloc(4096)
      result = Pointer(LibC::Spwd).malloc(1)

      ret = entry.fill_c_struct(result, buffer, 4096_u64)
      ret.should eq 0

      String.new(result.value.sp_namp).should eq "alice"
      String.new(result.value.sp_pwdp).should eq "!"
      result.value.sp_lstchg.should eq 18000
      result.value.sp_max.should eq 99999
    end
  end
end

describe NssExec::BufferWriter do
  describe "#write_string" do
    it "writes a string and returns a pointer within the buffer" do
      buf = Pointer(UInt8).malloc(100)
      writer = NssExec::BufferWriter.new(buf, 100_u64)

      ptr = writer.write_string("hello")
      ptr.should_not be_nil
      String.new(ptr.not_nil!).should eq "hello"
    end

    it "returns nil when buffer is too small" do
      buf = Pointer(UInt8).malloc(3)
      writer = NssExec::BufferWriter.new(buf, 3_u64)

      # "hello" needs 6 bytes (5 + NUL), only 3 available
      writer.write_string("hello").should be_nil
    end

    it "writes multiple strings sequentially" do
      buf = Pointer(UInt8).malloc(100)
      writer = NssExec::BufferWriter.new(buf, 100_u64)

      p1 = writer.write_string("abc")
      p2 = writer.write_string("def")
      p1.should_not be_nil
      p2.should_not be_nil
      String.new(p1.not_nil!).should eq "abc"
      String.new(p2.not_nil!).should eq "def"
    end
  end

  describe "#write_string_array" do
    it "writes a NULL-terminated array of strings" do
      buf = Pointer(UInt8).malloc(4096)
      writer = NssExec::BufferWriter.new(buf, 4096_u64)

      arr = writer.write_string_array(["a", "b", "c"])
      arr.should_not be_nil
      arr = arr.not_nil!
      String.new(arr[0]).should eq "a"
      String.new(arr[1]).should eq "b"
      String.new(arr[2]).should eq "c"
      arr[3].null?.should be_true
    end

    it "writes a NULL-only array for empty input" do
      buf = Pointer(UInt8).malloc(4096)
      writer = NssExec::BufferWriter.new(buf, 4096_u64)

      arr = writer.write_string_array([] of String)
      arr.should_not be_nil
      arr.not_nil![0].null?.should be_true
    end
  end
end
