/*========================================================================*
  Patching Activity display script -- part of SPAM
 *========================================================================*/

function patchact(jdata)
{
  //--- set-up HTML when the script is first run

  if($('div#pa_hide').css('display') == 'none') {
    $('div#pa_hide').css('display','block');
    $('span#pa_mode span.pa_sel').click(function() {
      $('span#pa_mode span.pa_act').toggleClass('pa_act');
      $(this).toggleClass('pa_act');
      patchact(jdata);
    });
    $('span#pa_period span.pa_sel').click(function() {
      $('span#pa_period span.pa_act').toggleClass('pa_act');
      $(this).toggleClass('pa_act');
      patchact(jdata);
    });
  }

  //--- find

  var mode = $('span#pa_mode span.pa_act').attr('id').substr(3);
  var period = $('span#pa_period span.pa_act').attr('id').substr(3);
  var div_a = $('div#patch1');
  var div_b = $('div#patch2');
  var empty = 1;
  div_a.empty();
  div_b.empty();
  for(k in jdata[mode][period]) {
    var name = jdata[mode][period][k][0];
    var val = jdata[mode][period][k][1];
    div_a.append(name + '<br>');
    div_b.append(val + '<br>');
    empty = 0;
  }
  if(empty) {
    div_a.append('<span class="pa_inact">no activity</span>');
  }
}


$(document).ready(function() {
  $.get('spam-backend.cgi', { q: "patchact" }, function(jdata) {
    if(jdata.status == 'ok') { patchact(jdata); }
  });
});
