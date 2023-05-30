/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Add patches
  
  The UI to facilitate adding patching into database.
 *==========================================================================*/

 
module.exports = addPatchesForm;

function addPatchesForm(shared, state) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  jq_table,
  jq_tbody,
  prefill,
  site_mode = shared.site_mode,
  modPortList = require('./portlist.js');


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
  var 
    site = $(this).val(),
    set_mode;
    
  set_mode = function(outlet) {
    if(outlet) {
      $('table.addpatch').trigger('addpmode', ['outlet']);
    } else {
      $('table.addpatch').trigger('addpmode', ['cponly']);
    }
  };

  if(site) { localStorage.setItem('addpatchsite', site); }
  if(site in site_mode) {
    set_mode(site_mode[site]);
  } else {
    $.post(shared.backend, { r : 'usecp', site: $(this).val() }, function(data) {
      if(data.status == 'ok') {
        site_mode[site] = data.result;
        set_mode(site_mode[site]);
      }
    });
  }
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
  jq_tbody.find('td').not(':first').removeClass();
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

  $('button[name=addp_submit]')
    .removeClass('svg-check').addClass('svg-spinner');
  $.post(shared.backend, arg, function(data) {

    // display feedback data from backend; this is run even when the
    // actual database transaction fails; the data from backends are:
    //  * normalized field values
    //  * validation result
    //  * error messages for validation failures

    $('button[name=addp_submit]')
      .removeClass('svg-spinner').addClass('svg-check');
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
      /*if(data.search.status == 'ok') {
        new modPortList(
          shared, { beResponse: data, mount: 'div#addp_updsum', template: 'srcres' },
          function() { $('div#addp_updsum p.srcsummary').remove(); }
        );
      }*/
    }
    
    // display update summary/conflicting row(s), the callback removes the
    // standard "N matching entries found" message from DOM
    
    if('search' in data && data.search.status == 'ok') {
      new modPortList(
        shared,
        { beResponse: data, mount: 'div#addp_updsum', template: 'srcres' },
        function() { $('div#addp_updsum p.srcsummary').remove(); }
      );
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
  
  // prefill

  if('values' in state) {
    prefill = state.values;
  }
  if(prefill) {
    if('host' in prefill) {
      $('input[name=addp_sw00]').val(prefill.host);
    }
    if('portname' in prefill) {
      $('input[name=addp_pt00]').val(prefill.portname);
    }
    if('cp' in prefill) {
      $('input[name=addp_cp00]').val(prefill.cp);
    }
    if('outlet' in prefill) {
      $('input[name=addp_ou00]').val(prefill.outlet);
    }

    // site from prefill -- if there are prefilled data, automatically switch
    // the site to the site associated with the host
    $.post(shared.backend, { r: 'usecp', site: null, host: prefill.host}, data => {
      if(data.status == 'ok') {
        console.log('Site: ', data.site);
      }
    });

  }

  // callbacks for table rows

  jq_tbody.find('tr')
    .on('add', addTableRow)
    .on('remove', removeTableRow);

  // callbacks for table

  jq_table
    .on('renumber', renumberTable)
    .on('addpmode', switchMode)
    .on('statmsg', rowStatusMessage)
    .on('reset', formReset);

  // callback for site SELECT

  $('select[name=addp_site]').on('change', changeSite)

  // populate 'site' SELECT

  $('select[name=addp_site]').each(function(idx, el) {
    $('div#addpatch').addClass('spinner');
    shared.populate_select_sites(idx, el, function(idx, el) {
      $('div#addpatch').removeClass('spinner');
      if(prefill && 'host' in prefill) {
        $.post(shared.backend, { r: 'usecp', site: null, host: prefill.host}, data => {
          if(data.status == 'ok') {
            $(el).val(data.site).trigger('change');
          }
        });
      } else {
        shared.set_value_from_storage(el);
      }
    });
  });

  // callbacks for +/- buttons
  
  jq_tbody.find('button[name^="addp_dl"]')
  .on('click', function(evt) {
    $(this).trigger('remove');
    evt.preventDefault();
  });
  
  jq_tbody.find('button[name^="addp_ad"]')
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
