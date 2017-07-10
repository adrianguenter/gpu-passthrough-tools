package AGLib::SysInfo;
use strict;
use warnings;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(cpuinfo linux_version pci_devs_by_class pci_ids pci_vga_devices)],
  groups => {
    default => [qw()],
    cpu => [qw(cpuinfo)],
    pci => [qw(pci_devs_by_class pci_ids pci_vga_devices)],
  },
};

sub cpuinfo {
  # each element of @cpus refers to a physical chip (and socket)
  # the array is therefore indexed by the 'physical id' field from /proc/cpuinfo
  my @cpus = ();
  open my $fh, '<', '/proc/cpuinfo';
  local $/ = "\n\n";
  while (my $chunk = <$fh>) {
    my $cpu = {};
    for my $line (split(/\n/, $chunk)) {
      $line =~ /(?<name>\w+(?:\s+\w+)*)\s*: (?<value>.+)/;
      $cpu->{$+{name}} = $+{value};
    }
    if defined $cpus[$cpu->{'physical id'}] {
      push $cpus[$cpu->{'physical id'}]{core_list}, $cpu->{processor};
      next;
    }
    $cpus[$cpu->{'physical id'}] = {
      freq_max => slurp(
        '/sys/devices/system/cpu/cpu'.$cpu->{processor}.'/cpufreq/cpuinfo_max_freq'),
      vendor => $cpu->{vendor_id},
      flags => $cpu->{flags},
      core_count => $cpu->{'cpu cores'},
      core_list => @{[$cpu->{processor}]},
      cache_size => $cpu->{'cache size'},
      threads_per_core => int($cpu->{siblings} / $cpu->{'cpu cores'}),
      model_name => $cpu->{'model name'},
      x64 => $cpu->{flags} =~ /\blm\b/,
      hvm => $cpu->{flags} =~ /\b(vmx|svm)\b/,
    };
  }
  return @cpus;
}

sub linux_version {
  assert_readable '/proc/version';
  my $build_string = slurp '/proc/version';
  $build_string =~
    /^Linux version (?<full>(?<version>\d+)(?:\.(?<patchlevel>\d+)(?:\.(?<sublevel>\d+))?)?(?<extraversion>[^\s]+)?)/
  or FATAL 'Failed to parse <b>/proc/version</b>: ', color('white'), $build_string;
  
  return {
    build        => $build_string,
    full         => $+{full},
    version      => $+{version},
    patchlevel   => $+{patchlevel},
    sublevel     => $+{sublevel},
    extraversion => $+{extraversion},
  };
}

sub pci_devs_by_class {
  @_ && $_[0] =~ RE_HEX_BYTE or FATAL 'First argument is required';
  my $class    = shift;
  my $subclass = @_ && $_[0] =~ RE_HEX_BYTE ? shift : undef;
  my $prog_if  = @_ && $_[0] =~ RE_HEX_BYTE ? shift : undef;
  my $class_exp    = $class;
  my $subclass_exp = RE_HEX_BYTE;
  my $progif_exp   = RE_HEX_BYTE;
  my @host_bridges = glob('/sys/devices/pci[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]');
  my @devs = ();
  my $result = \@devs;
  find({
      wanted => sub {
        push @devs, substr($_, 12) if
          not -l $_ and -f "${_}/class" and -f "${_}/vendor" and -f "${_}/device" and
          slurp({dochecks => 0}, "${_}/class") =~ /^(0?x)?${class_exp}${subclass_exp}${progif_exp}$/i;
      },
      no_chdir => 1
    },
    @host_bridges
  );
  return $result;
}

sub pci_ids {
  #   {
  #     [vendor_int] => {
  #       raw_id => [vendor_raw],
  #       id => [vendor_int],
  #       name => [vendor_name],
  #       devices => {
  #         [device_int] => {
  #           raw_id => [device_raw],
  #           id => [device_int],
  #           name => [device_name],
  #           subsystems => {
  #             [subdevice_int] => {
  #               vendor_raw_id => [subvendor_raw],
  #               vendor_id => [subvendor_int],
  #               device_raw_id => [subdevice_raw],
  #               device_id => [subdevice_int],
  #               name => [subsystem_name]
  #             }
  #           }
  #         },
  #         [device_int] => ...
  #       }
  #     },
  #     [vendor_int] => ...
  #   }
  # 
  # Vendor lookup:
  # $vendor = pci_ids->{hex('104a')};
  #
  # Device lookup:
  # $device = pci_ids->{hex('104a')}{devices}{hex('0010')};
  #
  # Subsystem device lookup:
  # $subsys_device = pci_ids->{hex('104a')}{devices}{hex('0010')}{subsystems}{@{[hex('1681'), hex('c010')]}};
  #
  # TODO:
  # - Add filter support to speed up process (vendor, vendor+device, vendor+device+subvendor, vendor+device+subvendor+subdevice)
  # - Multiple filter capability would be ideal so a list of devices to grab can be given
  #
  my $path = '';
  if (-r '/usr/share/hwdata/pci.ids') {
    $path = '/usr/share/hwdata/pci.ids';
  } else {
    $path = abs_path __DIR__ . '/../pci.ids';
    assert_readable $path;
  }
  my $vendor_exp = RE_HEX_2BYTES; # or a dynamic list of 'vid1|vid2|vid3|...'
  my $device_exp = RE_HEX_2BYTES; # or a dynamic list generated at the end of vendor block (around undef $curr_device)
  my $subvendor_exp = RE_HEX_2BYTES; # or a dynamic list generated at the end of device block
  my $subdevice_exp = RE_HEX_2BYTES; # or a dynamic list generated at the end of device block
  my %vendors = ();
  my $result = \%vendors; # this should change further down if filter(s) are specified
                          # return a single device/subsys hash, or list of hashes in that case!
  my $curr_vendor;
  my $curr_device;
  open my $fh, '<', $path;
  while (my $line = <$fh>) {
    chomp($line);
    if ($line eq '' or $line =~ /^(?:\s*#|\s+$)/) {
      next; # ignore blank lines and comments
    } elsif ($line =~ / # match and process vendor lines
      ^(?<vendor_raw>${vendor_exp})
      \s+(?<vendor_name>.*)
      \s*$
    /x) {
      my $vendor_int = hex($+{vendor_raw});
      $curr_vendor = $vendors{$vendor_int} = {
        id      => $vendor_int,     # integer
        raw_id  => $+{vendor_raw},  # 4-char hex string
        name    => $+{vendor_name},
        devices => {}
      };
      undef $curr_device; # clear $curr_device here for proper subsystem matching
    } elsif ($line =~ / # match and process device lines
      ^\t(?<device_raw>${device_exp})
      \s+(?<device_name>.*)
      \s*$
    /x) {
      $curr_vendor or FATAL 
        qq(No vendor defined while parsing <b>${path}</b> at line <b>${.}</b>: ), "\n",
        color('white'), $line;
      my $device_int = hex($+{device_raw});
      $curr_device = $curr_vendor->{devices}{$device_int} = {
        vendor_id     => $curr_vendor->{id},     # integer
        vendor_raw_id => $curr_vendor->{raw_id}, # 4-char hex string
        id            => $device_int,            # integer
        raw_id        => $+{device_raw},         # 4-char hex string
        name          => $+{device_name},
        subsystems    => {}
      };
    } elsif ($line =~ / # match and process subsystem lines
      ^\t\t(?<subvendor_raw>${subvendor_exp})
      \s+(?<subdevice_raw>${subdevice_exp})
      \s+(?<subsys_name>.*)
      \s*$
    /x) {
      $curr_device or FATAL
        qq(No device defined while parsing <b>${path}</b> at line <b>${.}</b>: ), "\n",
        color('white'), $line;
      my $subvendor_int = hex($+{subvendor_raw});
      my $subdevice_int = hex($+{subdevice_raw});
      $curr_device->{subsystems}{@{[$subvendor_int, $subdevice_int]}} = {
        supravendor_id     => $curr_vendor->{id},     # integer
        supravendor_raw_id => $curr_vendor->{raw_id}, # 4-char hex string
        supradevice_id     => $curr_device->{id},     # integer
        supradevice_raw_id => $curr_device->{raw_id}, # 4-char hex string
        vendor_id          => $subvendor_int,         # integer
        vendor_raw_id      => $+{subvendor_raw},      # 4-char hex string
        id                 => $subdevice_int,         # integer
        raw_id             => $+{subdevice_raw},      # 4-char hex string
        name               => $+{subsystem_name},
      };
    } elsif ($line =~ /^C ${\(RE_HEX_BYTE)}\s+/) {
      last; # exit the loop when we reach the class definitions
    } else {
      # should we ignore lines we can't parse instead of dying?
      FATAL qq(Failed parsing <b>${path}</b> at line <b>${.}</b>: ), "\n",
        color('white'), $line;
    }
  }
  return $result;
}

sub pci_vga_devices {
  my $pci_ids = pci_ids;
  my %vgadevs;
  my $result = \%vgadevs;
  @vgadevs{@{pci_devs_by_class '03', '00', '00'}} = ();
  while (my ($dev_addr) = each %vgadevs) {
    my $dev = $vgadevs{$dev_addr} = {};
    my $dev_sysfs = "/sys/devices${dev_addr}";
    $dev->{addr} = $dev_addr;
    $dev->{sysfs} = $dev_sysfs;
    $dev->{boot_vga} = int slurp "${dev_sysfs}/boot_vga";
    $dev->{driver_sysfs} = abs_path "${dev_sysfs}/driver";
    $dev->{driver} = basename $dev->{driver_sysfs};
    $dev->{iommu_sysfs} = abs_path "${dev_sysfs}/iommu";
    $dev->{iommu_group_sysfs} = abs_path "${dev_sysfs}/iommu_group";
    $dev->{iommu_group} = int basename $dev->{iommu_group_sysfs};
    ($dev->{vendor_raw_id} = slurp "${dev_sysfs}/vendor") =~ s/^(0x)//i;
    $dev->{vendor_id} = hex $dev->{vendor_raw_id};
    ($dev->{device_raw_id} = slurp "${dev_sysfs}/device") =~ s/^(0x)//i;
    $dev->{device_id} = hex $dev->{device_raw_id};
    ($dev->{subvendor_raw_id} = slurp "${dev_sysfs}/subsystem_vendor") =~ s/^(0x)//i;
    $dev->{subvendor_id} = hex $dev->{subvendor_raw_id};
    ($dev->{subdevice_raw_id} = slurp "${dev_sysfs}/subsystem_device") =~ s/^(0x)//i;
    $dev->{subdevice_id} = hex $dev->{subdevice_raw_id};
    my $vendor_info = $pci_ids->{$dev->{vendor_id}};
    my $device_info = $vendor_info->{devices}{$dev->{device_id}};
    $dev->{vendor_name} = $vendor_info->{name};
    $dev->{device_name} = $device_info->{name};
    $dev->{subvendor_name} = $pci_ids->{$dev->{subvendor_id}}{name};
    #$dev->{subsystem_name} = $device_info->{subsystems}{@{[$dev->{subvendor_id}, $dev->{subdevice_id}]}}{name} if 
    #  exists $device_info->{subsystems}{@{[$dev->{subvendor_id}, $dev->{subdevice_id}]}};
    $dev->{via} = []; # TODO parse middle section of $dev_addr into this

    # TODO this is all broken. just create a new string with host bridge and device (prefix and suffix) stripped,
    #      then work on that.
    my @dev_addr_parts = split m%/%, $dev_addr;
    say Dumper(\@dev_addr_parts);

    my ($host_bridge_addr) = $dev_addr =~ m%^(/[^/]+)%;
    $dev_addr = dirname $dev_addr;
    while (dirname $dev_addr ne $host_bridge_addr) {
      push @{$dev->{via}}, basename $dev_addr;
      $dev_addr = dirname $dev_addr; # WARNING THIS DESTROYS $dev_addr!!!
      say $dev_addr;exit;
    }
    #say Dumper($d);
  }
  return $result;
}
