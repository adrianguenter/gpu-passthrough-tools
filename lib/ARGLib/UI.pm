package AGLib::UI;
use strict;
use warnings;
use 5.015;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(tags2esc FATAL WARN INFO DEBUG)],
  groups => {
    default => [qw(tags2esc FATAL WARN INFO DEBUG)],
  },
};

sub tags2esc {
  my $r = ''; # result string
  my %tags = ( # tag => esc. sequence list mappings
    b => [qw|[1m [21m|], # bold
    l => [qw|[2m [22m|], # light
    i => [qw|[3m [23m|], # italic
    u => [qw|[4m [24m|], # underline
    k => [qw|[5m [25m|], # blink
    r => [qw|[7m [27m|], # reverse/inverted
    h => [qw|[8m [28m|], # hidden
  );
  for my $s (@_) { # build output string first instead of running s/r on each input string
    $r .= $s;
  }
  while (my ($tag, $ptr_esc_seqs) = each %tags) { # iterate over tag => esc. sequence list mappings
    my @esc_seqs = @{$ptr_esc_seqs}; # dereference esc. sequence list
    $r =~ s%<${tag}>%\e${esc_seqs[0]}%g; # replace open tag
    $r =~ s%</${tag}>%\e${esc_seqs[1]}%g; # replace close tag
  }
  return $r;
}
# Test:
#say tags2esc('<b>bold</b> <l>light</l> <i>italic</i> <b><i>bold italic</i></b> ', 
#  '<u>underline</u> <k>blink</k> <r>inverted</r> <h>hidden</h>');

sub FATAL {
  my %args = (exit_code => 1); # defaults
  @_ and (ref $_[0] eq 'HASH') and do { %args = (%args, %{(shift)}) };
  say STDERR "\n", color('red bold'), 'FATAL in ', color('reset rgb522'), sub_name(1), ': ',
    tags2esc(@_), color('reset');
  exit $args{exit_code};
}

sub WARN {
  say STDERR color('yellow bold'), 'Warning: ', color('reset rgb553'), tags2esc(@_), color('reset');
}

sub INFO {
  say STDERR color('rgb444 bold'), 'Info: ', color('reset rgb555'), tags2esc(@_), color('reset');
}

sub DEBUG {
  say STDERR color('blue bold'), 'Debug: ', color('reset rgb444'), tags2esc(@_), color('reset');
}
