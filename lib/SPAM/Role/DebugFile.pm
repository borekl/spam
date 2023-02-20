package SPAM::Role::DebugFile;

# support code for creating debug traces; add this to any class you want to log
# from and specify '_debug_filename' moniker, that gets turned into the actual
# log filename as "debug.MONIKER.PID.log"; the filehandle of the log is an
# instance attribute

use Moo::Role;
use experimental 'signatures';

use Carp;
use SQL::Abstract::Pg;

requires '_debug_filename';

# debugging filehandle
has _debug_fh => ( is => 'rw' );

#-------------------------------------------------------------------------------
sub _dbg_open ($self)
{
  my $fh;

  # do nothing if debugging not turned on or _debug_filename is undefined; note
  # that this will fail if _debug_filename is not class attribute -- every class
  # that wants to use this role must therefore define the attribute
  return undef unless $ENV{SPAM_DEBUG} && $self->_debug_filename;

  # open filehandle, or return alread open one
  if(!$self->_debug_fh) {
    my $filename = sprintf('debug.%s.%d.log', $self->_debug_filename, $$);
    open($fh, '>>', $filename) or croak "Cannot open debug log '$filename' ($!)";
    printf $fh "==> START OF DEBUG (%s)\n", $self->_debug_filename;
    $self->_debug_fh($fh);
  } else {
    $fh = $self->_debug_fh;
  }
}

#-------------------------------------------------------------------------------
# close log
sub _dbg_close ($self)
{
  if($self->_debug_fh) {
    my $fh = $self->_debug_fh;
    print $fh "==> END OF DEBUG\n";
    close($fh);
    $self->_debug_fh(undef);
  }
}

#-------------------------------------------------------------------------------
# log a debugging message; if called without any arguments it closes the log
sub _dbg ($self, $fmt=undef, @args)
{
  my $fh = $self->_dbg_open;
  return unless $fh;
  printf $fh "--> $fmt\n", @args;
}

#-------------------------------------------------------------------------------
# Log a debugging message that contains SQL query; the arguments taken are same
# as to select/insert/update/delete methods of SQL::Abstract::Pg, but prepended
# with the name of the operation. The method returns the arguments it gets
# omitting that one prepended argument. This makes it possible to simply wrap
# Mojo::Pg::Database call like this:
#   $db->insert('table', { field1 => $val1 }) becomes
#   $db->insert($self->_dbg_db('insert', 'table', { field1 => $val1 }))
sub _dbg_db($self, $op, @args)
{
  my $fh = $self->_dbg_open;
  return @args unless $fh;

  # generate query string and list of values from Mojo::Pg::Database method
  # arguments
  my $sqla = SQL::Abstract::Pg->new;
  my ($qry, @fields) = $sqla->$op(@args);
  # replace ? placeholders with %s placeholders and log the query with
  # placeholders replaced with values
  $qry =~ s/\?/%s/g;
  printf $fh "$qry\n", map { defined $_ ? "'$_'" : 'NULL' } @fields;
  # return the arguments to be used by a Mojo::Pg::Database method
  return @args;
}

1;
