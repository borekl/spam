/* Attempt at a module for Add Patches form module
 * """""""""""""""""""""""""""""""""""""""""""""""
 */
 
module.exports = addPatchesForm;

function addPatchesForm(shared) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  jq_table,
  jq_tbody;


/*--------------------------------------------------------------------------*
  Add table row.
 *--------------------------------------------------------------------------*/
 
function addTableRow(evt) 
{
  var jq_table_rows = jq_tbody.find('tr');
  if(jq_table_rows.length < 100) {
    var new_row = $(this).clone(true);
    new_row.find('input').val(null);
    var v = $(this).find('input[name^="addp_sw"]').val();
    var n = $(this).find('input[name^="addp_sw"]').attr('name');
    $(new_row).find('input[name='+n+']').val(v);
    new_row.find('td').each(function(idx, el) {
      if(idx != 0) { $(el).removeClass(); }
    });
    $(this).after(new_row).trigger('renumber');
  }
};


/*--------------------------------------------------------------------------*
  Remove single row from table.
 *--------------------------------------------------------------------------*/

function removeTableRow(evt)
{
  var jq_table_rows = jq_tbody.find('tr');
  if(jq_table_rows.length > 1) {
    $(this).remove();
    jq_table.trigger('renumber');
  }
  evt.preventDefault();
}
  

/*--------------------------------------------------------------------------*
  Table renumbering.
 *--------------------------------------------------------------------------*/

function renumberTable(evt)
{
  // iterate over table rows
  jq_tbody.find('tr').each(function() {
    var
      row = $(this).index(),
      row_s = row + '';
    
    if(row_s.length < 2) { row_s = '0' + row_s; }
    
    // iterate of TD elements in the row
    $(this).find('td').each(function() {
      var col = $(this).index(), name, jq_el;
      col_s = col;
      if(col == 0) {
        $(this).text(row + 1 + '.');
      } else {
        $(this).find('input,button,span').each(function() {
          name = $(this).attr('name');
          if(!name) { name = $(this).attr('id'); }
          if(name) {
            name = name.replace(/\d\d$/, row_s);
            $(this).attr('name', name);
          }
        });
      }
    });
  });
  evt.stopPropagation();
}


/*--------------------------------------------------------------------------*
  Switching between 'cp-only' and 'cp-and-outlets' mode. This should be the
  TABLE element; mode is 'cponly' or 'outlet'.
 *--------------------------------------------------------------------------*/

function switchMode(evt, mode)
{
  if($(this).attr('data-mode') != mode) {
    $('table.addpatch').find('th,td').each(function() {
      var tag = $(this).prop('tagName'),
          idx = $(this).index();
      if(
        tag == 'TD' && idx == 4 ||
        tag == 'TH' && idx == 3
      ) {
        if(mode == 'cponly') {  $(this).hide(); }
        else if(mode == 'outlet') { $(this).show(); }
      }
    })
    $(this).attr('data-mode', mode);
  }
}


/*--------------------------------------------------------------------------*
  Change site.
 *--------------------------------------------------------------------------*/

function changeSite(evt)
{
  var site = $(this).val();

  console.log("site changed to %s", site);
  if(site) { localStorage.setItem('addpatchsite', site); }
  $.get(shared.backend, { r : 'usecp', site: $(this).val() }, function(data) {
    if(data.status == 'ok') {
      if(data.result) {
        $('table.addpatch').trigger('addpmode', ['outlet']);
      } else {
        $('table.addpatch').trigger('addpmode', ['cponly']);
      }
    }
  });
}


/*--------------------------------------------------------------------------*
  Row status message. mesg = message string; cl = optional class for SPAN
  element.
 *--------------------------------------------------------------------------*/

function rowStatusMessage(evt, mesg, cl)
{
  var 
    target = evt.target,
    tag = $(target).prop('tagName');

  // event.target is not a TR, try to find TR in the chain of ancestors
  if(tag != 'TR') {
    target = $(evt.target).parents('tr').eq(0);
  }

  // do nothing if we don't have valid row
  if(!target) { return; }

  // find the status message TD
  var el = $(target).children('td').last().children('span'),
      tx = el.html();
  if(tx && mesg) {
    el.removeClass().html(tx + '<br>' + mesg);
  } else {
    el.removeClass().html(mesg);
  }
  if(cl) { el.addClass(cl); }
}


/*--------------------------------------------------------------------------*
  Form reset.
 *--------------------------------------------------------------------------*/

function formReset(evt)
{
  jq_tbody.find('tr').not(':first').trigger('remove');
  jq_tbody.find('tr').find('input').val(undefined);
  jq_tbody.children('tbody').find('td').not(':first').removeClass();
  $('div#addp_mesg p').addClass('nodisp');
  $('div#addp_updsum').empty();
  $('table.addpatch tbody tr').trigger('statmsg', '');
  evt.preventDefault();
}


/*--------------------------------------------------------------------------*
  Form submmit.
 *--------------------------------------------------------------------------*/
 
function formSubmit(evt)
{
  //--- object to hold the POST data for the backend query

  var arg = {
    r: 'addpatch',
    site: $('select[name=addp_site]').val()
  };

  //--- move form data into the 'arg' object

  jq_tbody.find('input').each(function(idx) {
    arg[$(this).attr('name')] = $(this).val();
  });

  //--- backend query

  $.post(shared.backend, arg, function(data) {

    // display feedback data from backend; this is run even when the
    // actual database transaction fails; the data from backends are:
    //  * normalized field values
    //  * validation result
    //  * error messages for validation failures

    jq_tbody.find('tr').each(function() {
      $(this).trigger('statmsg', '');
    });
    if('result' in data) {
      data.result.forEach(function(val, idx) {
        for(var field in val) {
          var jq_input = $('input[name=' + val[field].name + ']');
          jq_input.val(val[field].value);
          if(val[field].err) {
            jq_input.trigger('statmsg', val[field].err);
          }
          if(!val[field].valid) {
            jq_input.parent().addClass('invalid');
          } else {
            jq_input.parent().removeClass('invalid');
          }
        }
      });
    }

    // general error message

    $('#addp_mesg p').addClass('nodisp');
    if('status' in data && data.status == 'error') {
      $('#addp_mesg p.error span').text(data.errmsg.toLowerCase());
      $('#addp_mesg p.error').removeClass('nodisp');
    }

    // success

    if('status' in data && data.status == 'ok') {
      jq_table.trigger('reset');
      $('#addp_mesg p.success').removeClass('nodisp');
      if(data.search.status == 'ok') {
        dust.render('srcres', data, function(err, out) {
          $('div#addp_updsum').html(out).find('p.srcsummary').remove();
        });
      }
    }
  }, 'json');

}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/
 
dust.render('addpatch', {}, function(err, out) {
  
  // render content
  
  $('#content').html(out);
  jq_table = $('table.addpatch'),
  jq_tbody = $('table.addpatch tbody');
  
  $('select[name=addp_site]').each(shared.pss);
  
  // callbacks for table rows
  
  jq_tbody.find('tr')
    .on('add', addTableRow)
    .on('remove', removeTableRow);

  // callbacks for table

  jq_table
    .on('renumber', renumberTable)
    .on('addpmode', switchMode)
    .on('statmsg', rowStatusMessage);

  // callback for site SELECT

  $('select[name=addp_site]').on('change', changeSite)

  // callbacks for +/- buttons
  
  jq_tbody.find('button[name^="addp_dl"')
  .on('click', function(evt) {
    $(this).trigger('remove');
    evt.preventDefault();
  });
  
  jq_tbody.find('button[name^="addp_ad"')
  .on('click', function(evt) {
     $(this).trigger('add');
     evt.preventDefault();
  });

  // callbacks for submit/reset buttons

  $('button[name=addp_reset]').on('click', formReset);
  $('button[name=addp_submit]').on('click', formSubmit);
  
});


/*--- end of module --------------------------------------------------------*/

}