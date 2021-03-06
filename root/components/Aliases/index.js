/*
 * @flow
 * Copyright (C) 2018 MetaBrainz Foundation
 *
 * This file is part of MusicBrainz, the open internet music database,
 * and is licensed under the GPL version 2, or (at your option) any
 * later version: http://www.gnu.org/licenses/gpl-2.0.txt
 */

const React = require('react');
const {withCatalystContext} = require('../../context');
const Frag = require('../Frag');
const {l} = require('../../static/scripts/common/i18n');
const EntityLink = require('../../static/scripts/common/components/EntityLink');
const entityHref = require('../../static/scripts/common/utility/entityHref');
const AliasTable = require('./AliasTable');

type Props = {
  +$c: CatalystContextT,
  +aliases: $ReadOnlyArray<AliasT>,
  +allowEditing?: boolean,
  +entity: CoreEntityT,
};

const Aliases = ({$c, aliases, allowEditing = $c.user ? !$c.user.is_editing_disabled : false, entity}: Props) => {
  return (
    <Frag>
      <h2>{l('Aliases')}</h2>
      <p>
        {l('An alias is an alternate name for an entity. They typically contain common mispellings or variations of the name and are also used to improve search results. View the {doc|alias documentation} for more details.',
          {__react: true, doc: '/doc/Aliases'})}
      </p>
      {aliases && aliases.length
        ? <AliasTable aliases={aliases} allowEditing={allowEditing} entity={entity} />
        : <p>{l('{entity} has no aliases.', {__react: true, entity: <EntityLink entity={entity} key='entity' />})}</p>}
      {allowEditing
        ? (
          <p>
            <a href={entityHref(entity, `/add-alias`)}>
              {l('Add a new alias')}
            </a>
          </p>
        )
        : null}
    </Frag>
  );
};

export default withCatalystContext(Aliases);
