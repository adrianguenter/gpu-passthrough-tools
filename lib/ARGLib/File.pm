package AGLib::File;
use strict;
use warnings;
use 5.015;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(assert_readable slurp)],
  groups => {
    default => [qw(assert_readable slurp)],
  },
};

sub assert_readable {
  for my $fh (@_) {
    -r $fh or FATAL qq(<b>$fh</b> does not exist or is not readable by the current user);
  }
}

sub slurp {
  my %args = (dochecks => 1); # defaults
  @_ and ref $_[0] eq 'HASH' and do { %args = (%args, %{(shift)}) };
  my $path = shift; # TODO: rewrite slurp as a loop that slurps all remaining positional arguments
  my $error;
  if ($args{dochecks} && (
   not -e $path    and do { $error = q(does not exist) }
   or -d $path     and do { $error = q(is a directory) }
   or not -r $path and do { $error = q(is not readable by the current user) }
  ) ) {
    my ($x, $error_file, $error_line) = caller;
    $error_file = abs_path $error_file;
    FATAL qq(Path <b>${path}</b> ${error} at <b>${error_file}</b> line <b>${error_line}</b>);
  }
  open my $fh, '<', $path;
  local $/ = undef;
  my $slurp = <$fh>;
  chop($slurp);
  close $fh;
  return $slurp;
}
