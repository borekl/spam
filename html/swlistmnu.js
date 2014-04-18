/*==========================================* 
  Code for switching "groups" in Switch List
 *==========================================*/


$(document).ready(function() {
  var width = $("table").eq(0).width();
  $("table").width(width);
  $("div.swlist_grpsel").css("display","block");
  var x = $.cookie('spam_swlistgrp');
  if(!x) { x = 'all'; }
  if(x != 'all') {
    $("#tabdiv_all").css("display","none");
    $("#tabdiv_" + x).css("display","block");
  }
  $("#mentry_" + x).addClass("swlist_grpsel1");
});


function grp_sel(x) {
  $("div[id^='tabdiv_']").css("display","none");
  $("#tabdiv_" + x).css("display","block");
  $("span[id^='mentry_']").removeClass("swlist_grpsel1");
  $("#mentry_" + x).addClass("swlist_grpsel1");
  if(x != 'err') {
    $.cookie('spam_swlistgrp', x, { expires : 999 });
  }
};
