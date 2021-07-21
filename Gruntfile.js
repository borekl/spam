module.exports = function(grunt)
{

 grunt.initConfig({
   pkg: grunt.file.readJSON('package.json'),

   dustjs: {
     main : {
       files: {
         'html/templates/templates.js': [ 'html/templates/*.dust' ]
       }
     }
   },
   
   browserify: {
     main: {
       files: {
         'html/bundle.js' : [ 'html/spam.js', 'html/templates/templates.js' ]
       }
     },
     dev: {
       files: {
         'html/bundle.js' : [ 'html/spam.js', 'html/templates/templates.js' ]
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
         { nonull: true, src: 'lib/SPAM/Cmdline.pm', dest: '../prod/lib/SPAM/Cmdline.pm' },
         { nonull: true, src: 'lib/SPAM/Config.pm', dest: '../prod/lib/SPAM/Config.pm' },
         { nonull: true, src: 'lib/SPAM/Entity.pm', dest: '../prod/lib/SPAM/Entity.pm' },
         { nonull: true, src: 'lib/SPAM/EntityTree.pm', dest: '../prod/lib/SPAM/EntityTree.pm' },
         { nonull: true, src: 'lib/SPAM/MIB.pm', dest: '../prod/lib/SPAM/MIB.pm' },
         { nonull: true, src: 'lib/SPAM/MIBobject.pm', dest: '../prod/lib/SPAM/MIBobject.pm' },
       ]
     },
     www: {
       files: [
         { nonull: true, src: 'html/bundle.js', dest: '../prod/html/bundle.js' },
         { nonull: true, src: 'html/default.css', dest: '../prod/html/default.css' },
         { nonull: true, src: 'html/index.html', dest: '../prod/html/index.html' },
         { nonull: true, src: 'html/spam-backend.cgi', dest: '../prod/html/spam-backend.cgi' }
       ]
     },
     coll: {
       files: [
         { nonull: true, src: 'spam.pl', dest: '../prod/spam.pl' },
         { nonull: true, src: 'SPAMv2.pm', dest: '../prod/SPAMv2.pm' },
         { nonull: true, src: 'SPAM_SNMP.pm', dest: '../prod/SPAM_SNMP.pm' }
       ]
     }
   },

   sed: {
     www: {
       pattern: 'spam-dev',
       replacement: 'spam',
       path: '../prod/html/index.html'
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
