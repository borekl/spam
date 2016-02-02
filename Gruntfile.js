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
   }

 });

 grunt.loadNpmTasks("grunt-dustjs");
 grunt.loadNpmTasks("grunt-browserify");

 grunt.registerTask('default', [ 'dustjs', 'browserify' ]);

}