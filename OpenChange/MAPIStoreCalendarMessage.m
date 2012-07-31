/* MAPIStoreCalendarMessage.m - this file is part of SOGo
 *
 * Copyright (C) 2011 Inverse inc
 *
 * Author: Wolfgang Sourdeau <wsourdeau@inverse.ca>
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3, or (at your option)
 * any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

/* TODO:
   - merge common code with tasks
   - take the tz definitions from Outlook */

#include <talloc.h>
#include <util/attr.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSCalendarDate.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimeZone.h>
#import <NGObjWeb/WOContext+SoObjects.h>
#import <NGExtensions/NSObject+Logs.h>
#import <NGCards/iCalAlarm.h>
#import <NGCards/iCalCalendar.h>
#import <NGCards/iCalEvent.h>
#import <NGCards/iCalDateTime.h>
#import <NGCards/iCalPerson.h>
#import <NGCards/iCalTimeZone.h>
#import <NGCards/iCalTrigger.h>
#import <SOGo/SOGoPermissions.h>
#import <SOGo/SOGoUser.h>
#import <Appointments/SOGoAppointmentFolder.h>
#import <Appointments/SOGoAppointmentObject.h>
#import <Appointments/iCalEntityObject+SOGo.h>
#import <Mailer/NSString+Mail.h>

#import "iCalEvent+MAPIStore.h"
#import "MAPIStoreAppointmentWrapper.h"
#import "MAPIStoreCalendarAttachment.h"
#import "MAPIStoreCalendarFolder.h"
#import "MAPIStoreContext.h"
#import "MAPIStoreMapping.h"
#import "MAPIStoreRecurrenceUtils.h"
#import "MAPIStoreTypes.h"
#import "MAPIStoreUserContext.h"
#import "NSDate+MAPIStore.h"
#import "NSData+MAPIStore.h"
#import "NSObject+MAPIStore.h"
#import "NSString+MAPIStore.h"
#import "NSValue+MAPIStore.h"

#import "MAPIStoreCalendarMessage.h"

#undef DEBUG
#include <stdbool.h>
#include <gen_ndr/exchange.h>
#include <gen_ndr/property.h>
#include <libmapi/libmapi.h>
#include <mapistore/mapistore.h>
#include <mapistore/mapistore_errors.h>
#include <mapistore/mapistore_nameid.h>

// extern void ndr_print_AppointmentRecurrencePattern(struct ndr_print *ndr, const char *name, const struct AppointmentRecurrencePattern *r);

@implementation SOGoAppointmentObject (MAPIStoreExtension)

- (Class) mapistoreMessageClass
{
  return [MAPIStoreCalendarMessage class];
}

@end

@implementation MAPIStoreCalendarMessage

+ (enum mapistore_error) getAvailableProperties: (struct SPropTagArray **) propertiesP
                                       inMemCtx: (TALLOC_CTX *) memCtx
{
  BOOL listedProperties[65536];
  NSUInteger count;

  memset (listedProperties, NO, 65536 * sizeof (BOOL));
  [super getAvailableProperties: propertiesP inMemCtx: memCtx];
  for (count = 0; count < (*propertiesP)->cValues; count++)
    listedProperties[(*propertiesP)->aulPropTag[count] >> 16] = YES;
  [MAPIStoreAppointmentWrapper fillAvailableProperties: *propertiesP
                                        withExclusions: listedProperties];

  return MAPISTORE_SUCCESS;
}

- (id) init
{
  if ((self = [super init]))
    {
      calendar = nil;
      masterEvent = nil;
    }

  return self;
}

- (void) _setupAttachmentParts
{
  NSUInteger count, max;
  NSArray *events;
  NSString *newKey;
  MAPIStoreCalendarAttachment *attachment;
  NSUInteger aid;

  events = [calendar events];
  max = [events count];
  for (count = 1; count < max; count++)
    {
      attachment = [MAPIStoreCalendarAttachment
                      mapiStoreObjectInContainer: self];
      /* we now that there are no attachments yet, so we can assume that the
         right AID is 0 from the start */
      aid = count - 1;
      [attachment setAID: aid];
      [attachment setEvent: [events objectAtIndex: count]];
      newKey = [NSString stringWithFormat: @"%ul", aid];
      [attachmentParts setObject: attachment forKey: newKey];
    }
}

- (id) initWithSOGoObject: (id) newSOGoObject
              inContainer: (MAPIStoreObject *) newFolder
{
  MAPIStoreContext *context;
  MAPIStoreUserContext *userContext;
  iCalCalendar *origCalendar;
  MAPIStoreAppointmentWrapper *appointmentWrapper;

  if ((self = [super initWithSOGoObject: newSOGoObject
                            inContainer: newFolder]))
    {
      if ([newSOGoObject isNew])
        {
          ASSIGN (calendar, [iCalCalendar groupWithTag: @"vcalendar"]);
          [calendar setVersion: @"2.0"];
          [calendar setProdID: @"-//Inverse inc.//OpenChange+SOGo//EN"];
          masterEvent = [iCalEvent groupWithTag: @"vevent"];
          [calendar addChild: masterEvent];
          [masterEvent setCreated: [NSCalendarDate date]];
        }
      else
        {
          origCalendar = [sogoObject calendar: YES secure: YES];
          calendar = [origCalendar mutableCopy];
          masterEvent = [[calendar events] objectAtIndex: 0];
          [self _setupAttachmentParts];
        }
      context = [self context];
      userContext = [self userContext];
      appointmentWrapper
        = [MAPIStoreAppointmentWrapper wrapperWithICalEvent: masterEvent
                                                    andUser: [userContext sogoUser]
                                             andSenderEmail: nil
                                                 inTimeZone: [userContext timeZone]
                                         withConnectionInfo: [context connectionInfo]];
      [self addProxy: appointmentWrapper];
    }

  return self;
}

- (void) dealloc
{
  [calendar release];
  [super dealloc];
}

/* getters */
- (int) getPidLidFInvited: (void **) data
                 inMemCtx: (TALLOC_CTX *) memCtx
{
  return [self getYes: data inMemCtx: memCtx];
}

- (int) getPidTagMessageClass: (void **) data
                     inMemCtx: (TALLOC_CTX *) memCtx
{
  *data = talloc_strdup (memCtx, "IPM.Appointment");

  return MAPISTORE_SUCCESS;
}

- (int) getPidLidAppointmentMessageClass: (void **) data
                                inMemCtx: (TALLOC_CTX *) memCtx
{
  *data = talloc_strdup (memCtx, "IPM.Appointment");

  return MAPISTORE_SUCCESS;
}

- (int) getPidLidSideEffects: (void **) data // TODO
                    inMemCtx: (TALLOC_CTX *) memCtx
{
  *data = MAPILongValue (memCtx,
                         seOpenToDelete | seOpenToCopy | seOpenToMove
                         | seCoerceToInbox | seOpenForCtxMenu);

  return MAPISTORE_SUCCESS;
}

- (int) getPidTagProcessed: (void **) data inMemCtx: (TALLOC_CTX *) memCtx
{
  return [self getYes: data inMemCtx: memCtx];
}

- (void) getMessageData: (struct mapistore_message **) dataPtr
               inMemCtx: (TALLOC_CTX *) memCtx
{
  struct mapistore_message *msgData;

  [super getMessageData: &msgData inMemCtx: memCtx];
  /* HACK: we know the first (and only) proxy is our appointment wrapper
     instance, but this might not always be true */
  [[proxies objectAtIndex: 0] fillMessageData: msgData
                                     inMemCtx: memCtx];

  *dataPtr = msgData;
}

/* sender representing */
// - (int) getPidTagSentRepresentingEmailAddress: (void **) data
//                                      inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagSenderEmailAddress: data inMemCtx: memCtx];
// }

// - (int) getPidTagSentRepresentingAddressType: (void **) data
//                                     inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getSMTPAddrType: data inMemCtx: memCtx];
// }

// - (int) getPidTagSentRepresentingName: (void **) data
//                              inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagSenderName: data inMemCtx: memCtx];
// }

// - (int) getPidTagSentRepresentingEntryId: (void **) data
//                                 inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagSenderEntryId: data inMemCtx: memCtx];
// }

/* attendee */
// - (int) getPidTagReceivedByAddressType: (void **) data
//                        inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [appointmentWrapper getPidTagReceivedByAddressType: data
//                                                    inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedByEmailAddress: (void **) data
//                            inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [appointmentWrapper getPidTagReceivedByEmailAddress: data
//                                                        inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedByName: (void **) data
//                    inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [appointmentWrapper getPidTagReceivedByName: data
//                                                inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedByEntryId: (void **) data
//                       inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [appointmentWrapper getPidTagReceivedByEntryId: data
//                                                   inMemCtx: memCtx];
// }

// /* attendee representing */
// - (int) getPidTagReceivedRepresentingEmailAddress: (void **) data
//                                  inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagReceivedByEmailAddress: data inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedRepresentingAddressType: (void **) data
//                              inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getSMTPAddrType: data inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedRepresentingName: (void **) data
//                          inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagReceivedByName: data inMemCtx: memCtx];
// }

// - (int) getPidTagReceivedRepresentingEntryId: (void **) data
//                             inMemCtx: (TALLOC_CTX *) memCtx
// {
//   return [self getPidTagReceivedByEntryId: data inMemCtx: memCtx];
// }

- (int) getPidTagResponseRequested: (void **) data
                          inMemCtx: (TALLOC_CTX *) memCtx
{
  return [self getYes: data inMemCtx: memCtx];
}

- (NSString *) _uidFromGlobalObjectId
{
  NSData *objectId;
  NSString *uid = nil;
  char *bytesDup, *uidStart;
  NSUInteger length;

  /* NOTE: we only handle the generic case at the moment, see
     MAPIStoreAppointmentWrapper */
  objectId = [properties
               objectForKey: MAPIPropertyKey (PidLidGlobalObjectId)];
  if (objectId)
    {
      length = [objectId length];
      bytesDup = talloc_array (NULL, char, length + 1);
      memcpy (bytesDup, [objectId bytes], length);
      bytesDup[length] = 0;
      uidStart = bytesDup + length - 1;
      while (uidStart != bytesDup && *(uidStart - 1))
        uidStart--;
      if (uidStart > bytesDup && *uidStart)
        uid = [NSString stringWithUTF8String: uidStart];
      talloc_free (bytesDup);
    }

  return uid;
}

- (void) _fixupAppointmentObjectWithUID: (NSString *) uid
{
  NSString *cname, *url;
  MAPIStoreMapping *mapping;
  uint64_t objectId;
  SOGoAppointmentFolder *folder;
  SOGoAppointmentObject *newObject;
  WOContext *woContext;

  cname = [[container sogoObject] resourceNameForEventUID: uid];
  if (cname)
    isNew = NO;
  else
    cname = [NSString stringWithFormat: @"%@.ics", uid];

  mapping = [self mapping];

  url = [NSString stringWithFormat: @"%@%@", [container url], cname];
  folder = [container sogoObject];
  /* reinstantiate the old sogo object and attach it to self */
  woContext = [[self userContext] woContext];
  if (isNew)
    newObject = [SOGoAppointmentObject objectWithName: cname
                                          inContainer: folder];
  else
    {
      /* dissociate the object url from the old object's id */
      objectId = [mapping idFromURL: url];
      [mapping unregisterURLWithID: objectId];
      newObject = [folder lookupName: cname
                           inContext: woContext
                             acquire: NO];
    }

  /* dissociate the object url associated with this object, as we want to
     discard it */
  objectId = [self objectId];
  [mapping unregisterURLWithID: objectId];
      
  /* associate the new object url with this object id */
  [mapping registerURL: url withID: objectId];

  [newObject setContext: woContext];
  ASSIGN (sogoObject, newObject);
}

- (BOOL) subscriberCanReadMessage
{
  NSArray *roles;

  roles = [self activeUserRoles];

  return ([roles containsObject: SOGoCalendarRole_ComponentViewer]
          || [roles containsObject: SOGoCalendarRole_ComponentDAndTViewer]
          || [self subscriberCanModifyMessage]);
}

- (BOOL) subscriberCanModifyMessage
{
  BOOL rc;
  NSArray *roles = [self activeUserRoles];

  if (isNew)
    rc = [roles containsObject: SOGoRole_ObjectCreator];
  else
    rc = ([roles containsObject: SOGoCalendarRole_ComponentModifier]
          || [roles containsObject: SOGoCalendarRole_ComponentResponder]);

  return rc;
}

- (void) _updateAttachedEvent: (MAPIStoreCalendarAttachment *) attachment
                      withUID: (NSString *) uid
{
  iCalEvent *newEvent;
  SOGoUser *activeUser;

  newEvent = [iCalEvent groupWithTag: @"vevent"];
  [calendar addToEvents: newEvent];
  activeUser = [[self context] activeUser];
  [newEvent setUid: uid];
  [newEvent updateFromMAPIProperties: [attachment properties]
                       inUserContext: [self userContext]
                      withActiveUser: activeUser];
}
                
- (void) _updateAttachedEvents
{
  NSMutableArray *otherEvents;
  NSArray *allAttachments;
  NSUInteger count, max;
  NSString *uid;

  /* cleanup all recurring events */
  otherEvents = [[calendar events] mutableCopy];
  [otherEvents removeObject: masterEvent];
  [calendar removeChildren: otherEvents];
  [otherEvents release];

  uid = [masterEvent uid];

  allAttachments = [attachmentParts allValues];
  max = [allAttachments count];
  for (count = 0; count < max; count++)
    [self _updateAttachedEvent: [allAttachments objectAtIndex: count]
                     withUID: uid];
}

- (void) save
{
  // iCalCalendar *vCalendar;
  // NSCalendarDate *now;
  NSString *uid;
  // iCalEvent *newEvent;
  // iCalPerson *userPerson;
  SOGoUser *activeUser;

  if (isNew)
    {
      uid = [self _uidFromGlobalObjectId];
      if (uid)
        {
          /* Hack required because of what's explained in oxocal 3.1.4.7.1:
             basically, Outlook creates a copy of the event and then removes
             the old instance. We perform a trickery to avoid performing those
             operations in the backend, in a way that enables us to recover
             the initial instance and act solely on it. */
          [self _fixupAppointmentObjectWithUID: uid];
        }
      else
        uid = [SOGoObject globallyUniqueObjectId];
      [masterEvent setUid: uid];
      [sogoObject setNameInContainer:
                    [NSString stringWithFormat: @"%@.ics", uid]];
    }

  // [self logWithFormat: @"-save, event props:"];
  // MAPIStoreDumpMessageProperties (newProperties);

  // now = [NSCalendarDate date];

  activeUser = [[self context] activeUser];
  [masterEvent updateFromMAPIProperties: properties
                          inUserContext: [self userContext]
                         withActiveUser: activeUser];
  [self _updateAttachedEvents];
  [sogoObject updateContentWithCalendar: calendar
                            fromRequest: nil];

  [self updateVersions];
}

- (id) lookupAttachment: (NSString *) childKey
{
  return [attachmentParts objectForKey: childKey];
}

- (MAPIStoreAttachment *) createAttachment
{
  MAPIStoreCalendarAttachment *newAttachment;
  uint32_t newAid;
  NSString *newKey;

  newAid = [[self attachmentKeys] count];

  newAttachment = [MAPIStoreCalendarAttachment
                    mapiStoreObjectInContainer: self];
  [newAttachment setAID: newAid];
  newKey = [NSString stringWithFormat: @"%ul", newAid];
  [attachmentParts setObject: newAttachment
                      forKey: newKey];
  [attachmentKeys release];
  attachmentKeys = nil;

  return newAttachment;
}

- (int) setReadFlag: (uint8_t) flag
{
  return MAPISTORE_SUCCESS;
}

@end
