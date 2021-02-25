/* -*- Mode: javascript; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* JavaScript for SOGoPreferences */

(function() {
  'use strict';

  angular.module('SOGo.PreferencesUI', ['ui.router', 'sgCkeditor', 'angularFileUpload', 'SOGo.Common', 'SOGo.MailerUI', 'SOGo.ContactsUI', 'SOGo.Authentication', 'as.sortable'])
    .config(configure)
    .run(runBlock);

  /**
   * @ngInject
   */
  configure.$inject = ['$stateProvider', '$urlServiceProvider'];
  function configure($stateProvider, $urlServiceProvider) {
    $stateProvider
      .state('preferences', {
        abstract: true,
        views: {
          preferences: {
            templateUrl: 'preferences.html',
            controller: 'PreferencesController',
            controllerAs: 'app'
          }
        }
      })
      .state('preferences.general', {
        url: '/general',
        views: {
          module: {
            templateUrl: 'generalPreferences.html'
          }
        }
      })
      .state('preferences.calendars', {
        url: '/calendars',
        views: {
          module: {
            templateUrl: 'calendarsPreferences.html'
          }
        }
      })
      .state('preferences.addressbooks', {
        url: '/addressbooks',
        views: {
          module: {
            templateUrl: 'addressbooksPreferences.html'
          }
        }
      })
      .state('preferences.mailer', {
        url: '/mailer',
        views: {
          module: {
            templateUrl: 'mailerPreferences.html'
          }
        }
      });

    // if none of the above states are matched, use this as the fallback
    $urlServiceProvider.rules.otherwise('/general');
  }


  /**
   * @ngInject
   */
  runBlock.$inject = ['$window', '$log', '$transitions', '$state'];
  function runBlock($window, $log, $transitions, $state) {
    if (!$window.DebugEnabled)
      $state.defaultErrorHandler(function() {
        // Don't report any state error
      });
    $transitions.onError({ to: 'preferences.**' }, function(transition) {
      if (transition.to().name != 'preferences' &&
          !transition.ignored()) {
        $log.error('transition error to ' + transition.to().name + ': ' + transition.error().detail);
        $state.go({ state: 'preferences' });
      }
    });
  }

})();
