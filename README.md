# Switch Ports Activity Monitor

Switch Ports Activity Monitor (SPAM) is an application for monitoring
network switches. It consists of *collector* and *web application*, both
talking to a backend PostgreSQL database. The general purpose is to give
administrator quick overview of the switches (ports, trunks, FRUs etc.) and
it also has some support to keep track of what is wired where.

SPAM is written in perl (collector) and JavaScript with dust templating
library (web application).

*SPAM is an internal application, so it is not very well documented.*

# Note

Following two headers need to be set in this way, so that the backend knows
username and client IP (both recorded for each creation/change):

    RequestHeader set X-Remote-User expr=%{REMOTE_USER}
    RequestHeader set X-Remote-IPAddr expr=%{REMOTE_ADDR}

Example Apache configuration, that sets up reverse proxy along with required
request headers and authentication.

    <Location /spam/>
      Options +Indexes +FollowSymLinks +MultiViews +ExecCGI
      AddType image/svg+xml svg svgz
      AddEncoding gzip svgz
      AuthName "Switch Port Activity Monitor"
      AuthType Basic
      AuthBasicProvider msad
      require valid-user
      RequestHeader set X-Remote-User expr=%{REMOTE_USER}
      RequestHeader set X-Remote-IPAddr expr=%{REMOTE_ADDR}
      ProxyPass "http://127.0.0.1:3000/"
      ProxyPassReverse "http://127.0.0.1:3000/"
    </Location>

# Development

Run the backend with morbo development web server (it automatically reloads
app files). The default is to run on localhost on port 3000.

    morbo -m development  ./spam-web

For testing from command-line, be sure to provide user name (via X-Remote-User
header), you'll get an error if you don't. Also arguments must be passed as form
fields, ie. with Content-Typer: x-www-form-urlencoded. For example, with httpie
you can do something like this:

   http -f http://127.0.0.1:3000/api/v0/ \
     X-Remote-User:johndoe \
     r=search host=SWITCH01 mode=portlist

When the backend is contacted without any arguments, simple JSON-formatted
status message should be returned:

    $ http http://127.0.0.1:3000/api/v0/ X-Remote-User:johndoe
    
    HTTP/1.1 200 OK
    Content-Length: 48
    Content-Type: application/json;charset=UTF-8
    Date: Tue, 28 Apr 2026 13:50:45 GMT
    Server: Mojolicious (Perl)
    
    {
        "debug": true,
        "status": "ok",
        "userid": "johndoe"
    }
