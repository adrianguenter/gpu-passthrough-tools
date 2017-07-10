package AGLib::Base;
use strict;
use warnings;
use 5.015;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(sub_name)],
  groups => {
    default => [qw(sub_name)],
  },
};

BEGIN { $Exporter::Verbose=1 }

use constant RE_HEX_BYTE => '[[:xdigit:]]{2}';
use constant RE_HEX_2BYTES => '[[:xdigit:]]{4}';

# returns name of the calling subroutine (name of the subroutine sub_name is called from)
# first argument increases position in call stack to support helper subs like FATAL
sub sub_name { return ((caller(1+(@_ ? shift : 0)))[3]); }

sub __DIR__ { return dirname abs_path (caller)[1]; }
