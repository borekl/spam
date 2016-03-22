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
     main : {
       files: {
         'html/bundle.js' : [ 'html/spam.js', 'html/templates/templates.js' ]
       }
     }
   },
   
   copy: {
     www: {
       files: [
         { nonull: true, src: 'html/bundle.js', dest: '../prod/html/bundle.js' },
         { nonull: true, src: 'html/default.css', dest: '../prod/html/default.css' },
         { nonull: true, src: 'html/index.html', dest: '../prod/html/index.html.css' },
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
   }

 });

 grunt.loadNpmTasks("grunt-dustjs");
 grunt.loadNpmTasks("grunt-browserify");
 grunt.loadNpmTasks("grunt-contrib-copy");

 grunt.registerTask('default', [ 'dustjs', 'browserify' ]);
 grunt.registerTask('dist-www', [ 'copy:www' ]);
 grunt.registerTask('dist-coll', [ 'copy:coll' ]);
 grunt.registerTask('dist', [ 'copy:www', 'copy:coll' ]);
}

