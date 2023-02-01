# Switch Ports Activity Monitor

Switch Ports Activity Monitor (SPAM) is an application for monitoring
network switches. It consists of *collector* and *web application*, both
talking to a backend PostgreSQL database. The general purpose is to give
administrator quick overview of the switches (ports, trunks, FRUs etc.) and
it also has some support to keep track of what is wired where.

SPAM is written in perl (collector) and JavaScript with dust templating
library (web application).

# Note

SPAM is in transition from old CGI-based backend to new Mojolicious based one.
For this to work with the original front-end, following mapping must be set up
on the web server (assuming application path `/spam` and backend port 3000):

    ProxyPass /spam/spam-backend.cgi "http://127.0.0.1:3000/"
    ProxyPassReverse /spam/spam-backend.cgi "http://127.0.0.1:3000/"

Also following two headers need to be set in this way:

    RequestHeader set X-Remote-User expr=%{REMOTE_USER}
    RequestHeader set X-Remote-IPAddr expr=%{REMOTE_ADDR}
