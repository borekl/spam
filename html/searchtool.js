/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Search Tool
 *==========================================================================*/
 

module.exports = searchTool;

function searchTool(shared) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  modPortinfo = require('./portinfo.js');


/*--------------------------------------------------------------------------*
  Reset the Search Tool
 *--------------------------------------------------------------------------*/

function resetSearch(evt)
{
  $('div#result').empty();
  $('input').val('');
  $('select[name=site]').prop('selectedIndex', 0);
}


/*--------------------------------------------------------------------------*
  Submit search.
 *--------------------------------------------------------------------------*/

function submitSearch(evt)
{
  //--- put form fields into an object
  
  var form = { r: 'search' };
  $('input,select').each(function() {
    var 
      name = $(this).attr('name'),
      val = $(this).val();
    if((name == 'site' && val != 'any') || (name != 'site' && val)) {
      form[name] = val;
    }
  });
  
  //--- submit form data to backend, get results back
  
  $('div#srctool div').addClass('timer');
  $.get(shared.backend, form, function(search) {
  
  //--- replace form field values with normalized values supplied by the
  //--- backend, using ' as the first character in the form field inhibits
  //--- the normalization

    for(var field in search.params.normalized) {
      if(search.params.raw[field].substr(0,1) != "'") {
        $('input[name=' + field  + ']').val(search.params.normalized[field]);
      }
    }

  //--- display the result

    if(search.status == 'error') {
      alert('Search Fail!');
    } else {
      dust.render('srcres', search, function(err, out) {
        $('div#result').html(out);
        new modPortInfo(shared, 'table#srcres');
      });
    }
    $('div#srctool div').removeClass('timer');

  });
}
 

/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

dust.render('search', {}, function(err, out) 
{
  //--- render initial content

  $('#content').html(out);
  $('select[name=site]').each(shared.pss);
  
  //--- bind submit/reset buttons
  
  $('button#submit').click('on', submitSearch);
  $('button#reset').click('on', resetSearch);
  
});


/*--- end of module --------------------------------------------------------*/

}
