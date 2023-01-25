package SPAM::Web;

use Mojo::Base 'Mojolicious', -signatures;

sub startup ($self)
{
  my $r = $self->routes;
  
  $r->get('/' => sub ($c) {
    $c->render(text => 'Hello World!');
  });
}

1;
