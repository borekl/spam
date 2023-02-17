module.exports = function(grunt)
{

  grunt.initConfig({
    pkg: grunt.file.readJSON('package.json'),

    dustjs: {
      main : {
        files: {
          'public/templates/templates.js': [ 'public/templates/*.dust' ]
        }
      }
    },

    browserify: {
      main: {
        files: {
          'public/bundle.js' : [ 'public/spam.js', 'public/templates/templates.js' ]
        }
      },
      dev: {
        files: {
          'public/bundle.js' : [ 'public/spam.js', 'public/templates/templates.js' ]
        },
        options: {
          browserifyOptions: {
            debug: true
          }
        }
      }
    },

    copy: {
      common: {
        files: [
          // SPAM::
          { nonull: true, src: 'lib/SPAM/Cmdline.pm', dest: '../prod/lib/SPAM/Cmdline.pm' },
          { nonull: true, src: 'lib/SPAM/Config.pm', dest: '../prod/lib/SPAM/Config.pm' },
          { nonull: true, src: 'lib/SPAM/Entity.pm', dest: '../prod/lib/SPAM/Entity.pm' },
          { nonull: true, src: 'lib/SPAM/EntityTree.pm', dest: '../prod/lib/SPAM/EntityTree.pm' },
          { nonull: true, src: 'lib/SPAM/MIB.pm', dest: '../prod/lib/SPAM/MIB.pm' },
          { nonull: true, src: 'lib/SPAM/MIBobject.pm', dest: '../prod/lib/SPAM/MIBobject.pm' },
          { nonull: true, src: 'lib/SPAM/Host.pm', dest: '../prod/lib/SPAM/Host.pm' },
          { nonull: true, src: 'lib/SPAM/Keys.pm', dest: '../prod/lib/SPAM/Keys.pm' },
          // SPAM::Model::
          { nonull: true, src: 'lib/SPAM/Model/PortStatus.pm', dest: '../prod/lib/SPAM/Model/PortStatus.pm' },
          { nonull: true, src: 'lib/SPAM/Model/Porttable.pm', dest: '../prod/lib/SPAM/Model/Porttable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/Mactable.pm', dest: '../prod/lib/SPAM/Model/Mactable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/Arptable.pm', dest: '../prod/lib/SPAM/Model/Arptable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMPDbTable.pm', dest: '../prod/lib/SPAM/Model/SNMPDbTable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SwStat.pm', dest: '../prod/lib/SPAM/Model/SwStat.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP.pm', dest: '../prod/lib/SPAM/Model/SNMP.pm' },
          // SPAM::Model::SNMP::
          { nonull: true, src: 'lib/SPAM/Model/SNMP/Bridge.pm', dest: '../prod/lib/SPAM/Model/SNMP/Bridge.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/Platform.pm', dest: '../prod/lib/SPAM/Model/SNMP/Platform.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/EntityTree.pm', dest: '../prod/lib/SPAM/Model/SNMP/EntityTree.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/Boottime.pm', dest: '../prod/lib/SPAM/Model/SNMP/Boottime.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/CafSessionTable.pm', dest: '../prod/lib/SPAM/Model/SNMP/CafSessionTable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/PortTable.pm', dest: '../prod/lib/SPAM/Model/SNMP/PortTable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/ActiveVlans.pm', dest: '../prod/lib/SPAM/Model/SNMP/ActiveVlans.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/TrunkVlans.pm', dest: '../prod/lib/SPAM/Model/SNMP/TrunkVlans.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/IfTable.pm', dest: '../prod/lib/SPAM/Model/SNMP/IfTable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/Location.pm', dest: '../prod/lib/SPAM/Model/SNMP/Location.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/VmMembershipTable.pm', dest: '../prod/lib/SPAM/Model/SNMP/VmMembershipTable.pm' },
          { nonull: true, src: 'lib/SPAM/Model/SNMP/PortFlags.pm', dest: '../prod/lib/SPAM/Model/SNMP/PortFlags.pm' },
          // migrations
          { nonull: true, src: 'migrations/1/up.sql', dest: '../prod/migrations/1/up.sql' },
          { nonull: true, src: 'migrations/1/down.sql', dest: '../prod/migrations/1/down.sql' },
        ]
      },
      www: {
        files: [
          { nonull: true, src: 'public/bundle.js', dest: '../prod/public/bundle.js' },
          { nonull: true, src: 'public/default.css', dest: '../prod/public/default.css' },
          { nonull: true, src: 'public/index.html', dest: '../prod/public/index.html' },
          { nonull: true, src: 'spam-web', dest: '../prod/spam-web' },
          { nonull: true, src: 'lib/SPAM/Web.pm', dest: '../prod/lib/SPAM/Web.pm' },
          { nonull: true, src: 'lib/SPAM/Web/Legacy.pm', dest: '../prod/lib/SPAM/Web/Legacy.pm' }
        ]
      },
      coll: {
        files: [
          { nonull: true, src: 'spam-collector', dest: '../prod/spam-collector' },
          { nonull: true, src: 'lib/SPAM/Misc.pm', dest: '../prod/lib/SPAM/Misc.pm' },
          { nonull: true, src: 'lib/SPAM/SNMP.pm', dest: '../prod/lib/SPAM/SNMP.pm' },
          { nonull: true, src: 'lib/SPAM/DbTransaction.pm', dest: '../prod/lib/SPAM/DbTransaction.pm' },
          { nonull: true, src: 'lib/SPAM/Role/Switch.pm', dest: '../prod/lib/SPAM/Role/Switch.pm' },
          { nonull: true, src: 'lib/SPAM/Role/ArpSource.pm', dest: '../prod/lib/SPAM/Role/ArpSource.pm' },
          { nonull: true, src: 'lib/SPAM/Role/MessageCallback.pm', dest: '../prod/lib/SPAM/Role/MessageCallback.pm' }
        ]
      }
    },

    sed: {
      www: {
        pattern: 'spam-dev',
        replacement: 'spam',
        path: '../prod/public/index.html'
      }
    }

  });

  grunt.loadNpmTasks("grunt-dustjs");
  grunt.loadNpmTasks("grunt-browserify");
  grunt.loadNpmTasks("grunt-contrib-copy");
  grunt.loadNpmTasks('grunt-sed');

  grunt.registerTask('default', [ 'dustjs', 'browserify:dev' ]);
  grunt.registerTask('dist-www', [ 'dustjs', 'browserify:main', 'copy:common', 'copy:www', 'sed:www' ]);
  grunt.registerTask('dist-coll', [ 'copy:common', 'copy:coll' ]);
  grunt.registerTask('dist', [  'dustjs', 'browserify:main', 'copy:common', 'copy:www', 'sed:www', 'copy:coll' ]);
}
