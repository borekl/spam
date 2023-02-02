package SPAM::Web;

# dispatcher (aka router) for the web application backend; this code interfaces
# with the backend database and transforms data into JSON for the frontend

use Mojo::Base 'Mojolicious', -signatures;
use Feature::Compat::Try;
use Mojo::JSON;
use ONdb::Authorize;
use SPAM::Config;

sub startup ($self)
{
  my $cfg = SPAM::Config->instance(
    config_file => $self->home->child('spam.cfg.json')
  );

  # ensure config is loaded // if we find config is not loaded, the application
  # becomes completely inoperable and all requests return error
  if(!ref $cfg) {
    $self->routes->any('/' => sub ($c) {
      $c->render(
        json => { status => 'error', errmsg => 'Could not load configuration' }
      );
    });
    return;
  }

  # non-development log goes to a file (development default is stderr)
  if($self->app->mode ne 'development' && $cfg->logfile('web')) {
    $self->app->log->path($cfg->logfile('web'));
    $self->app->log->info(
      'Application started, log level ' . $self->app->log->level
    );
  }

  # authorization code // code shared with all requests
  my $r = $self->routes->under('/' => sub ($c) {

    # default stash content
    $c->stash(
      userid => $c->req->headers->header('X-Remote-User'),
      remoteaddr => $c->req->headers->header('X-Remote-IPAddr'),
      debug => Mojo::JSON->false,
    );

    # autorization instance
    my $auth = ONdb::Authorize->new(
      dbh => SPAM::Config->instance->get_dbi_handle('ondbui'),
      user => $c->stash('userid'),
      tab_assign => 'assign_new',
      tab_access => 'access_new',
      system => 'spam',
    );

    # get debug flag
    try {
      $c->stash(debug => Mojo::JSON->true) if $auth->authorize('debug');
    } catch($e) {
      $c->stash(dberr => $e);
    };

    1;
  });

  # parameter condition on verb (the 'r' parameter)
  $self->routes->add_condition(verb => sub ($rt, $c, $cap, $v) {
    ($c->req->body_params->param('r') // '') eq $v;
  });

  # parameter condition on verb (the 'r' parameter)
  $self->routes->add_condition(qverb => sub ($rt, $c, $cap, $v) {
    ($c->req->query_params->param('r') // '') eq $v;
  });

  # legacy endpoints // these use the legacy code from the original backend
  # (spam-backend.cgi) that currently resides in the SPAM::Web::Legacy class
  $r->post('/')->requires(verb => 'test')->to('legacy#test');
  $r->post('/')->requires(verb => 'swlist')->to('legacy#swlist');
  $r->post('/')->requires(verb => 'search')->to('legacy#search');
  $r->post('/')->requires(verb => 'portinfo')->to('legacy#portinfo');
  $r->post('/')->requires(verb => 'usecp')->to('legacy#usecp');
  $r->get('/')->requires(qverb => 'aux')->to('legacy#aux');
  $r->post('/')->requires(verb => 'addpatch')->to('legacy#addpatch');
  $r->post('/')->requires(verb => 'delpatch')->to('legacy#delpatch');
  $r->get('/')->requires(qverb => 'modwire')->to('legacy#modwire');
  $r->any('/')->to('legacy#default');

}

1;
