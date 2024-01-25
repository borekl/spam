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
