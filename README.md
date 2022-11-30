# Switch Ports Activity Monitor

Switch Ports Activity Monitor (SPAM) is an application for monitoring
network switches. It consists of *collector* and *web application*, both
talking to a backend PostgreSQL database. The general purpose is to give
administrator quick overview of the switches (ports, trunks, FRUs etc.) and
it also has some support to keep track of what is wired where.

SPAM is written in perl (collector) and JavaScript with dust templating
library (web application).
