/// <reference path="../pb_data/types.d.ts" />
// Steady 1.2 - answers kept on the patient's phone while the server couldn't be reached (the
// app's outbox) arrive later, once, with the time they were given:
//   checkins.clientId        the phone's own id for it: sent twice, stored once
//   checkins.answeredAt      when the patient answered (empty: when it arrived)
//   assignments.completionId the phone's id for a questionnaire or exercise it finished
// (assignments already have completedAt, which is now when the patient finished it.)
// SPDX-License-Identifier: AGPL-3.0-or-later

migrate((app) => {
  const checkins = app.findCollectionByNameOrId("checkins");
  checkins.fields.add(new TextField({ name: "clientId", max: 15, pattern: "^[a-z0-9]*$" }));
  checkins.fields.add(new DateField({ name: "answeredAt" }));
  checkins.indexes.push("CREATE UNIQUE INDEX idx_checkins_client ON checkins (patient, clientId) WHERE clientId != ''");
  app.save(checkins);
  const assignments = app.findCollectionByNameOrId("assignments");
  assignments.fields.add(new TextField({ name: "completionId", max: 15, pattern: "^[a-z0-9]*$" }));
  app.save(assignments);
}, (app) => {
  const checkins = app.findCollectionByNameOrId("checkins");
  checkins.fields.removeByName("clientId");
  checkins.fields.removeByName("answeredAt");
  checkins.indexes = checkins.indexes.filter((i) => i.indexOf("idx_checkins_client") < 0);
  app.save(checkins);
  const assignments = app.findCollectionByNameOrId("assignments");
  assignments.fields.removeByName("completionId");
  app.save(assignments);
});
