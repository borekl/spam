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
  modPortList = require('./portlist.js'),
  portList;


/*--------------------------------------------------------------------------*
  Reset the Search Tool
 *--------------------------------------------------------------------------*/

function resetSearch(evt)
{
  evt.preventDefault();
  $('div#result').empty();
  $('input').val('');
  $('select[name=site]').prop('selectedIndex', 0);
}


/*--------------------------------------------------------------------------*
  Submit search.
 *--------------------------------------------------------------------------*/

function submitSearch(evt)
{
  //--- no default FORM action

  evt.preventDefault();

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
  
  $('button#submit').removeClass('svg-check').addClass('svg-spinner');
  portList = new modPortList(
    shared, {
      beRequest: form, mount: 'div#result', template: 'srcres',
      error: 'error', norowsok: true
    },
    function(search) {
  
  //--- replace form field values with normalized values supplied by the
  //--- backend, using ' as the first character in the form field inhibits
  //--- the normalization

    for(var field in search.params.normalized) {
      if(search.params.raw[field].substr(0,1) != "'") {
        $('input[name=' + field  + ']').val(search.params.normalized[field]);
      }
    }
    $('button#submit').removeClass('svg-spinner').addClass('svg-check');

  },
  function(search) {
    $('button#submit').removeClass('svg-spinner').addClass('svg-check');
  });
}
 

/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

dust.render('search', {}, function(err, out) 
{
  //--- render initial content

  $('#content').html(out);
  $('select[name=site]').each(shared.populate_select_sites);
  
  //--- bind submit/reset buttons
  
  $('button#submit').click('on', submitSearch);
  $('button#reset').click('on', resetSearch);
  
});


/*--- end of module --------------------------------------------------------*/

}
