package Local::Base;
use strict;
use warnings;
use 5.014_004;

use Benchmark        qw(:all);
use Cwd              qw(abs_path);
use Data::Dumper     qw(Dumper);
use File::Basename;
use File::Find;
use Path::Class      qw(dir);
use Scalar::Util     qw(openhandle);
use Sys::Virt;
use Term::ANSIColor;
use XML::XPath;

# REFS
# http://vfio.blogspot.com/2015/05/vfio-gpu-how-to-series-part-3-host.html
# https://pve.proxmox.com/wiki/Pci_passthrough
# https://www.kernel.org/doc/Documentation/admin-guide/kernel-parameters.txt
# https://www.kernel.org/doc/Documentation/x86/x86_64/boot-options.txt (AMD + Intel)
# https://www.kernel.org/doc/Documentation/Intel-IOMMU.txt (Intel)
# https://bbs.archlinux.org/viewtopic.php?id=168555 (AMD)


use Sub::Exporter::Progressive -setup => {
  exports => [qw()],
  groups => {
    default => [qw()],
  },
};


sub adv_args_ex {
  # named params contained in first argument hash
  my %args = (a => 1, b => 2); # defaults
  @_ and ref $_[0] eq 'HASH' and do { %args = (%args, %{(shift)}) };
  # positional args
  my @array_arg = (@_ or say STDERR 'First positional argument is required') &&
    ref $_[0] eq '' ? shift :
    ref $_[0] eq 'ARRAY' ? @{(shift)} :
    say STDERR 'Invalid type for first positional agmument';
}
#adv_args_ex({'b' => 3, 'c' => 4}, 5, [6, 7]);exit;

sub colorprint {
  my $fh = shift;
  if (not defined openhandle $fh) {
    unshift @_, $fh;
    $fh = *STDOUT;
  }
  print $fh color(shift), @_, color('reset');
}

sub colorprint_err {
  colorprint *STDERR, @_;
}

sub colorsay {
  my $fh = shift;
  if (not defined openhandle $fh) {
    unshift @_, $fh;
    $fh = *STDOUT;
  }
  say $fh color(shift), @_, color('reset');
}

sub colorsay_err {
  colorsay *STDERR, @_;
}

sub say_issue {
  say STDOUT color('rgb303 bold'), '  ❎', color('reset rgb525'), ' ', @_, color('reset');
}

sub say_pass {
  say STDOUT color('rgb252 bold'), 'PASS:', color('reset rgb252'), ' ', @_, color('reset');
}

sub say_fail {
  say STDOUT color('rgb510 bold'), 'FAIL:', color('reset rgb532'), ' ', @_, color('reset');
}

sub check_requirements {
  my $feature = '';
  my $test = '';

  $test = 'kernel tests (version, mounted sysfs, IOMMU support, etc.)';

  DEBUG qq(Performing ${test});
  assert_readable qw(/proc/cmdline /proc/mounts);

  my $linux_version = linux_version;
  if ($linux_version->{version} < 4 
  or $linux_version->{version} == 4 and $linux_version->{patchlevel} < 8) {
    say_issue tag2esc q(This tool requires Linux <b>4.8 or newer</b>), "\n",
      color('white'), qq(System Linux version: <b>$linux_version->{full}</b>);
  }

  my $mounts = slurp('/proc/mounts');
  if (not $mounts =~ m%^sys\s+/sys\s+sysfs(?:\s|$)%m) {
    FATAL q(Sysfs doesn't appear to be mounted), "\n",
      color('white'), tag2esc q(As root, try: <b>mount -t sysfs sysfs /sys</b>);
  }

  if (not -r '/sys') {
    FATAL q(Sysfs is not readable by the current user);
  }

  if (not -d '/sys/class/iommu') {
    FATAL q(/sys/class/iommu is not a directory);
  }
  say_pass ucfirst qq(${test});

  

  # check if the CPU supports hardware virtualization (VT-x/d and AMD-V/Vi)
  my @cpuinfo = cpuinfo;
  my $kern_cmdline = slurp('/proc/cmdline');

  # this loop only runs once for single-socket systems
  # for multi-processor/socket systems each time a test fails the loop
  #   restarts with a new candidate
  for my $id (0 .. $#cpuinfo) {
    my $info = $cpuinfo[$id];
    my $last_cpu = 1 if $info == $cpuinfo[-1];

    # check for CPU hardware virtualization (VT-x or AMD-V)
    $feature = 'hardware virtualization';
    say '';
    DEBUG "Checking CPU in socket ${id} for ${feature} support";
    if (not defined $info->{hvm}) {
      WARN qq(CPU in socket ${id} [$info->{model_name}] didn't report ${feature} support);
      $last_cpu and FATAL q(No CPUs featuring support for ${feature} (Intel VT-x or AMD-V) detected);

      next; # test next cpu
    }
    say_pass qq(CPU hardware virtualization support [#${id}: $info->{model_name}]);

    # check for CPU IOMMU (VT-d or AMD-Vi) support
    $feature = 'IOMMU';
    say '';
    DEBUG "Checking CPU in socket ${id} for ${feature} support";
    my $sysfspath = dir('/sys/class/iommu'); # TODO: Determine if this is a suitable test for AMD setups
    $sysfspath->stat;
    if (not not $sysfspath->children) {
      say_fail "CPU ${feature} support [no IOMMU devices detected]";

      # detect issues
      if ($info->{hvm} eq 'vmx') {
        # Intel CPU
        if (not $kern_cmdline =~ /\sintel_iommu=(?!on)\s/) { # TODO: Revert to ?!off
          say_issue tag2esc('Intel CPU, but <b><i>intel_iommu</i></b> kernel parameter is missing or disabled (<i>intel_iommu=off</i>)');
          say '    ', tag2esc(
            '<b><u>/proc/cmdline</u></b>: <l>',
            $kern_cmdline =~ s%(\s+intel_iommu(=[^\s]+)?\s+)%</l><b>$1</b><l>%r,
            '</l>');
        }
      }
      elsif ($info->{hvm} eq 'svm') {
        # AMD CPU
        next if not (slurp '/proc/cmdline') =~ /\bamd_iommu=on\b/;
        print 'Oops, not done yet!';
        exit 99;
      }

      $last_cpu and FATAL q(No CPUs featuring enabled IOMMU support (Intel VT-d or AMD-Vi) detected);
      next; # test next CPU
    }
    say_pass qq(CPU IOMMU support [#${id}: $info->{model_name}]);

    # TODO: warning about low core count (influenced by existence/lack of smt)
    return 1;
  }
}

if ($^O ne 'linux') {
  FATAL q(This tool only supports Linux systems);
}

say check_requirements;

exit;


#### JUNK BELOW ####


# Use sysfs to get module info (to check vfio installation/version)

sub parse_os_release {
  # How to effectively parse "NAME=value\n" into hash?
  # /etc/os-release
}

sub test_mobo_support_iommu {
}

sub export_me {
   # stuff
}

sub export_me_too {
   # stuff
}

sub test_gpu_attached {
  my %params = @_;
  # TODO: Decide how to break up functions based on functionality provided by CLI
  #       "virt-gpu check Windows81" could check from bottom up, from vfio driver to domain configuration, essentially following the Arch Wiki OVMF passthrough guide. Could also add a mode switches for quick or specific checks?
  # TODO2: Getopt in Perl? What are the offerings?
  # TODO: Allow either domname or domid
  my $domain = exists $params{domname}
}

my $uri = "qemu:///system";

my $vmm = Sys::Virt->new(uri => $uri);

my @domains = $vmm->list_domains();

for my $dom (@domains) {
  print "Domain ", $dom->get_id, " ", $dom->get_name, "\n";
}

my $dom = $vmm->get_domain_by_name('Windows81');

my $xml = $dom->get_xml_description();

my $xp = XML::XPath->new(xml => $dom->get_xml_description());

my $pci_host_devices = $xp->find('/domain/devices/hostdev[@type="pci"]');
my $usb_host_devices = $xp->find('/domain/devices/hostdev[@type="usb"]');

for my $node ($pci_host_devices->get_nodelist) {
    print "FOUND\n\n",
        XML::XPath::XMLParser::as_string($node),
        "\n\n";
}

1;
